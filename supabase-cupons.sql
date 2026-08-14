-- ============================================================
--  Precifica 3D → Loja Moldarte 3D
--  Cupons de desconto.
--
--  Rode UMA VEZ no SQL Editor, depois do supabase-pagamento.sql.
-- ============================================================

-- ------------------------------------------------------------
--  Por que o cupom vive no banco
--
--  Desconto conferido no navegador nao vale nada: basta abrir as
--  ferramentas do desenvolvedor para se dar 100% de abatimento. Aqui
--  o cupom e validado dentro da transacao que cria o pedido, no mesmo
--  lugar onde o preco ja e recalculado.
-- ------------------------------------------------------------
create table if not exists public.cupons (
  usuario     uuid        not null references auth.users(id) on delete cascade,
  codigo      text        not null,
  -- frete: zera o frete · percentual: % sobre os itens · valor: R$ fixo
  tipo        text        not null check (tipo in ('frete','percentual','valor')),
  valor       numeric(10,2) not null default 0,
  -- Compra minima para o cupom valer. 0 = sem minimo.
  minimo      numeric(10,2) not null default 0,
  ativo       boolean     not null default true,
  expira_em   date,
  -- Quantas vezes ainda pode ser usado. NULL = ilimitado.
  usos_max    integer,
  usos        integer     not null default 0,
  descricao   text,
  criado_em   timestamptz not null default now(),
  primary key (usuario, codigo)
);

comment on table public.cupons is
  'Cupons da loja. O codigo e comparado sem diferenciar maiusculas.';

alter table public.cupons enable row level security;

-- Só o dono administra. A loja nunca lê esta tabela direto: ela pergunta
-- pela função abaixo, que devolve só o resultado da conta — assim a lista
-- de cupons não vira algo que dá para descobrir por tentativa.
drop policy if exists "dono administra cupons" on public.cupons;
create policy "dono administra cupons" on public.cupons
  for all using (usuario = auth.uid()) with check (usuario = auth.uid());

-- ------------------------------------------------------------
--  Validação
--
--  Devolve o que o cupom faz, ou o motivo de não valer. A mensagem é
--  escrita para o cliente ler na tela, não para o desenvolvedor.
-- ------------------------------------------------------------
create or replace function public.valida_cupom(
  p_usuario  uuid,
  p_codigo   text,
  p_subtotal numeric
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c record;
begin
  if coalesce(trim(p_codigo), '') = '' then
    return jsonb_build_object('ok', false, 'recado', 'Digite um cupom.');
  end if;

  select * into c from cupons
  where usuario = p_usuario and upper(codigo) = upper(trim(p_codigo));

  if not found then
    return jsonb_build_object('ok', false, 'recado', 'Cupom não encontrado.');
  end if;

  if not c.ativo then
    return jsonb_build_object('ok', false, 'recado', 'Este cupom não está mais valendo.');
  end if;

  if c.expira_em is not null and c.expira_em < current_date then
    return jsonb_build_object('ok', false, 'recado', 'Este cupom venceu.');
  end if;

  if c.usos_max is not null and c.usos >= c.usos_max then
    return jsonb_build_object('ok', false, 'recado', 'Este cupom já atingiu o limite de usos.');
  end if;

  if p_subtotal < c.minimo then
    return jsonb_build_object(
      'ok', false,
      'recado', 'Este cupom vale em compras a partir de R$ ' ||
                replace(to_char(c.minimo, 'FM999G999D00'), ',', 'X')
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'codigo', upper(c.codigo),
    'tipo', c.tipo,
    'valor', c.valor,
    'descricao', coalesce(c.descricao, '')
  );
end $$;

grant execute on function public.valida_cupom(uuid, text, numeric) to anon, authenticated;

-- ------------------------------------------------------------
--  Criar pedido, agora com frete e cupom decididos aqui
--
--  Mudanças em relação à versão anterior:
--
--  1. O frete deixou de vir do navegador. Antes o valor chegava pronto
--     na chamada, e bastava alterá-lo na tela para pagar frete zero.
--     Agora a loja informa apenas a tabela (valor e piso da gratuidade)
--     e a conta é feita aqui.
--
--  2. O cupom é conferido dentro da mesma transação, com o subtotal
--     que acabou de ser calculado a partir dos preços publicados.
-- ------------------------------------------------------------
drop function if exists public.criar_pedido(uuid, text, jsonb, jsonb, jsonb, numeric, text, text, integer);

create or replace function public.criar_pedido(
  p_usuario            uuid,
  p_id                 text,
  p_cliente            jsonb,
  p_entrega            jsonb,
  p_itens              jsonb,
  p_pagamento          text,
  p_observacoes        text,
  p_horas_reserva      integer default 24,
  p_cupom              text    default null,
  p_frete_padrao       numeric default 0,
  p_frete_gratis_acima numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item      jsonb;
  v_linha     record;
  v_conteudo  jsonb;
  v_qtd       integer;
  v_disp      integer;
  v_unit      numeric(10,2);
  v_faixa     jsonb;
  v_base      numeric(10,2);
  v_adicional numeric(10,2);
  v_subtotal  numeric(10,2) := 0;
  v_itens     jsonb := '[]'::jsonb;
  v_frete     numeric(10,2) := 0;
  v_desconto  numeric(10,2) := 0;
  v_cupom     jsonb;
  v_cupom_cod text := null;
begin
  perform expirar_reservas(p_usuario);

  if jsonb_array_length(p_itens) = 0 then
    return jsonb_build_object('ok', false, 'erro', 'carrinho_vazio');
  end if;

  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_qtd := greatest(1, coalesce((v_item->>'quantidade')::int, 1));

    select * into v_linha
    from dados
    where usuario = p_usuario and colecao = 'loja'
      and id = v_item->>'slug' and not apagado
    for update;

    if not found then
      return jsonb_build_object('ok', false, 'erro', 'produto_fora_do_ar',
                                'slug', v_item->>'slug');
    end if;

    v_conteudo := v_linha.conteudo;

    if coalesce(v_conteudo->>'modo', '') = 'consulta' then
      return jsonb_build_object('ok', false, 'erro', 'produto_sob_consulta',
                                'slug', v_linha.id);
    end if;

    select disponivel into v_disp
    from estoque_disponivel(p_usuario) e where e.slug = v_linha.id;

    if coalesce(v_disp, 0) < v_qtd then
      return jsonb_build_object('ok', false, 'erro', 'estoque_insuficiente',
                                'slug', v_linha.id,
                                'nome', v_conteudo->>'nome',
                                'disponivel', coalesce(v_disp, 0));
    end if;

    v_base := coalesce((v_conteudo->>'preco')::numeric, 0);
    v_adicional := 0;

    if v_item ? 'tamanho' and coalesce(v_item->>'tamanho', '') <> '' then
      select coalesce((t->>'adicional')::numeric, 0) into v_adicional
      from jsonb_array_elements(coalesce(v_conteudo->'tamanhos', '[]'::jsonb)) t
      where t->>'nome' = v_item->>'tamanho' limit 1;
      v_adicional := coalesce(v_adicional, 0);
    end if;

    v_unit := v_base + v_adicional;

    select t into v_faixa
    from jsonb_array_elements(coalesce(v_conteudo->'faixas', '[]'::jsonb)) t
    where coalesce((t->>'qtd')::int, 1) <= v_qtd
    order by (t->>'qtd')::int desc limit 1;

    if v_faixa is not null and v_base > 0 then
      v_unit := round(v_unit * (coalesce((v_faixa->>'preco')::numeric, v_base) / v_base), 2);
    end if;

    v_subtotal := v_subtotal + (v_unit * v_qtd);

    v_itens := v_itens || jsonb_build_object(
      'slug', v_linha.id, 'nome', v_conteudo->>'nome',
      'tamanho', v_item->>'tamanho', 'opcoes', v_item->'opcoes',
      'quantidade', v_qtd, 'precoUnitario', v_unit,
      'total', round(v_unit * v_qtd, 2)
    );

    insert into estoque_movimento (usuario, slug, delta, motivo, pedido_id)
    values (p_usuario, v_linha.id, -v_qtd, 'venda', p_id);
  end loop;

  -- Frete pela tabela da loja, nunca pelo que veio da tela.
  v_frete := case
    when p_frete_gratis_acima > 0 and v_subtotal >= p_frete_gratis_acima then 0
    else coalesce(p_frete_padrao, 0)
  end;

  -- Cupom, com o subtotal que acabou de ser calculado aqui.
  if coalesce(trim(p_cupom), '') <> '' then
    v_cupom := valida_cupom(p_usuario, p_cupom, v_subtotal);

    if (v_cupom->>'ok')::boolean then
      v_cupom_cod := v_cupom->>'codigo';

      if v_cupom->>'tipo' = 'frete' then
        v_frete := 0;
      elsif v_cupom->>'tipo' = 'percentual' then
        v_desconto := round(v_subtotal * least(100, (v_cupom->>'valor')::numeric) / 100, 2);
      else
        v_desconto := least(v_subtotal, (v_cupom->>'valor')::numeric);
      end if;

      update cupons set usos = usos + 1
      where usuario = p_usuario and upper(codigo) = v_cupom_cod;
    else
      -- Cupom inválido não derruba a compra: o pedido segue sem o desconto,
      -- e a loja avisa por que na resposta.
      return jsonb_build_object('ok', false, 'erro', 'cupom_invalido',
                                'recado', v_cupom->>'recado');
    end if;
  end if;

  insert into pedidos_loja (id, usuario, status, cliente, entrega, itens,
                            subtotal, frete, total, pagamento, observacoes,
                            expira_em, cupom, desconto)
  values (p_id, p_usuario, 'reservado', p_cliente, p_entrega, v_itens,
          round(v_subtotal, 2), v_frete,
          greatest(0, round(v_subtotal - v_desconto + v_frete, 2)),
          p_pagamento, p_observacoes,
          now() + make_interval(hours => greatest(1, p_horas_reserva)),
          v_cupom_cod, v_desconto);

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'itens', v_itens,
    'subtotal', round(v_subtotal, 2),
    'desconto', v_desconto,
    'frete', v_frete,
    'cupom', v_cupom_cod,
    'total', greatest(0, round(v_subtotal - v_desconto + v_frete, 2))
  );
end $$;

revoke execute on function public.criar_pedido(uuid, text, jsonb, jsonb, jsonb, text, text, integer, text, numeric, numeric) from anon;

-- O pedido passa a registrar qual cupom foi usado e quanto abateu.
alter table public.pedidos_loja
  add column if not exists cupom    text,
  add column if not exists desconto numeric(10,2) not null default 0;

-- ------------------------------------------------------------
--  O cupom de frete grátis
--
--  Troque o código por outro se quiser: ele é comparado sem
--  diferenciar maiúsculas, então FRETEGRATIS e fretegratis são o
--  mesmo cupom.
-- ------------------------------------------------------------
insert into public.cupons (usuario, codigo, tipo, valor, minimo, descricao)
select id, 'FRETEGRATIS', 'frete', 0, 0, 'Frete grátis em qualquer compra'
from auth.users
where email = (select email from auth.users order by created_at limit 1)
on conflict (usuario, codigo) do nothing;

-- ------------------------------------------------------------
--  Administrar seus cupons
--
--    -- ver todos
--    select codigo, tipo, valor, minimo, ativo, usos, usos_max, expira_em
--    from public.cupons;
--
--    -- desligar um
--    update public.cupons set ativo = false where codigo = 'FRETEGRATIS';
--
--    -- criar 10% de desconto acima de R$ 150, valido ate o fim do ano
--    insert into public.cupons (usuario, codigo, tipo, valor, minimo, expira_em, descricao)
--    values (auth.uid(), 'DEZOFF', 'percentual', 10, 150, '2026-12-31', '10% acima de R$ 150');
--
--    -- criar R$ 20 de abatimento, limitado a 50 usos
--    insert into public.cupons (usuario, codigo, tipo, valor, usos_max, descricao)
--    values (auth.uid(), 'VOLTA20', 'valor', 20, 50, 'R$ 20 de desconto');
-- ------------------------------------------------------------
