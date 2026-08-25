-- ============================================================
--  Moldarte 3D · clientes e cupom com dono
--
--  Rode DEPOIS de supabase-pix.sql. Este arquivo passa a ser o
--  ULTIMO da fila. Pode rodar mais de uma vez.
--
--  O QUE ELE TRAZ
--
--  1. Cupom com dono. Ate agora todo cupom valia para qualquer
--     um: quem recebesse o codigo de "primeira compra" podia
--     passar no grupo do WhatsApp e virava desconto para a rua
--     inteira. Agora um cupom pode ter um e-mail, e ai so quem
--     comprou com aquele e-mail consegue usar.
--
--  2. A lista de clientes. Os dados sempre estiveram aqui, so
--     nunca juntos: quem comprou esta nos pedidos, quem se
--     cadastrou para novidades esta nas mensagens, e ninguem
--     somava as duas coisas por pessoa. A funcao la embaixo faz
--     essa soma para o Precifica mostrar numa aba.
-- ============================================================

-- ------------------------------------------------------------
--  1 · cupom com dono
-- ------------------------------------------------------------
alter table public.cupons
  add column if not exists email text;

comment on column public.cupons.email is
  'Quando preenchido, o cupom so vale para quem comprar com este e-mail. Vazio = vale para qualquer um.';

-- Para achar rapido os cupons de uma pessoa na aba Clientes.
create index if not exists cupons_email_idx
  on public.cupons (usuario, lower(email))
  where email is not null;

-- A versao antiga tinha 3 argumentos. Sem apaga-la, as duas
-- ficariam vivas e a chamada por nome viraria ambigua — o banco
-- responderia "function is not unique" e nenhum cupom passaria.
drop function if exists public.valida_cupom(uuid, text, numeric);

create or replace function public.valida_cupom(
  p_usuario  uuid,
  p_codigo   text,
  p_subtotal numeric,
  -- E-mail de quem esta comprando. Chega vazio no conferidor da
  -- tela enquanto a pessoa ainda nao digitou o dela.
  p_email    text default null
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

  -- Cupom pessoal. Duas respostas diferentes de proposito: quem ainda
  -- nao disse quem e precisa saber o que fazer; quem disse e nao bate
  -- so precisa saber que este cupom nao e dele. Nenhuma das duas
  -- entrega de quem o cupom e.
  if coalesce(c.email, '') <> '' then
    if coalesce(trim(p_email), '') = '' then
      return jsonb_build_object(
        'ok', false,
        'recado', 'Este cupom é pessoal. Preencha seu e-mail nos seus dados para usá-lo.'
      );
    end if;

    if lower(trim(p_email)) <> lower(trim(c.email)) then
      return jsonb_build_object(
        'ok', false,
        'recado', 'Este cupom foi feito para outra pessoa e não vale nesta compra.'
      );
    end if;
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
    'pessoal', coalesce(c.email, '') <> '',
    'descricao', coalesce(c.descricao, '')
  );
end $$;

grant execute on function public.valida_cupom(uuid, text, numeric, text) to anon, authenticated;

-- ------------------------------------------------------------
--  2 · criar pedido, mandando o e-mail para o cupom
--
--  A funcao abaixo e a do supabase-pix.sql recortada linha por
--  linha, com uma unica linha diferente: a chamada da valida_cupom
--  passa a levar o e-mail do comprador. Nao foi redigitada —
--  reescrever a mao uma funcao que funciona ja custou caro aqui.
-- ------------------------------------------------------------
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
  p_frete_gratis_acima numeric default 0,
  -- Percentual de desconto no Pix. Quem manda a taxa e a loja, para o valor
  -- morar num lugar so; aqui so se aplica se o pagamento escolhido for Pix.
  p_desconto_pix       numeric default 0
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
  v_pix       numeric(10,2) := 0;
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
       and coalesce((t->>'qtd')::int, 1) > 1
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
    -- O e-mail de quem esta comprando vai junto: cupom pessoal so vale para
    -- o dono. Quem decide e a valida_cupom, aqui e no conferidor da tela.
    v_cupom := valida_cupom(p_usuario, p_cupom, v_subtotal, p_cliente->>'email');

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

  -- Desconto do Pix, sobre a mercadoria ja com o cupom aplicado. Frete fica
  -- de fora: ele nao e nosso, e dar 5% do frete seria pagar para entregar.
  if lower(coalesce(p_pagamento, '')) = 'pix' and coalesce(p_desconto_pix, 0) > 0 then
    v_pix := round(greatest(0, v_subtotal - v_desconto)
                   * least(100, p_desconto_pix) / 100, 2);
  end if;

  insert into pedidos_loja (id, usuario, status, cliente, entrega, itens,
                            subtotal, frete, total, pagamento, observacoes,
                            expira_em, cupom, desconto, desconto_pix)
  values (p_id, p_usuario, 'reservado', p_cliente, p_entrega, v_itens,
          round(v_subtotal, 2), v_frete,
          greatest(0, round(v_subtotal - v_desconto - v_pix + v_frete, 2)),
          p_pagamento, p_observacoes,
          now() + make_interval(hours => greatest(1, p_horas_reserva)),
          v_cupom_cod, v_desconto, v_pix);

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'itens', v_itens,
    'subtotal', round(v_subtotal, 2),
    'desconto', v_desconto,
    'descontoPix', v_pix,
    'frete', v_frete,
    'cupom', v_cupom_cod,
    'total', greatest(0, round(v_subtotal - v_desconto - v_pix + v_frete, 2))
  );
end $$;

revoke execute on function public.criar_pedido(uuid, text, jsonb, jsonb, jsonb, text, text, integer, text, numeric, numeric, numeric) from anon;

-- ------------------------------------------------------------
--  3 · a lista de clientes
--
--  Junta duas origens que nunca se falaram: quem comprou (pedidos)
--  e quem so deixou o e-mail para receber novidades (mensagens).
--  A chave e o e-mail em minusculas — e a unica coisa que a pessoa
--  repete a cada compra.
--
--  Conta como compra o que foi pago ou entregue. Pedido reservado
--  aparece separado, como "em aberto": ele ainda pode virar nada, e
--  somar no gasto faria voce premiar quem so encheu o carrinho.
-- ------------------------------------------------------------
create or replace function public.clientes_loja(p_usuario uuid)
returns table (
  email           text,
  nome            text,
  telefone        text,
  pedidos         integer,
  gasto           numeric,
  ticket          numeric,
  em_aberto       integer,
  primeira_compra timestamptz,
  ultima_compra   timestamptz,
  novidades       boolean,
  cupons_ativos   integer
)
language sql
stable
security definer
set search_path = public
as $$
  with compras as (
    select
      lower(trim(p.cliente->>'email'))                             as email,
      -- O nome e o telefone do pedido mais recente: se a pessoa corrigiu
      -- o nome na ultima compra, e esse que vale.
      (array_agg(p.cliente->>'nome'     order by p.criado_em desc))[1] as nome,
      (array_agg(p.cliente->>'telefone' order by p.criado_em desc))[1] as telefone,
      count(*) filter (where p.status in ('pago','entregue'))      as pedidos,
      coalesce(sum(p.total) filter (where p.status in ('pago','entregue')), 0) as gasto,
      count(*) filter (where p.status = 'reservado')               as em_aberto,
      min(p.criado_em) filter (where p.status in ('pago','entregue')) as primeira,
      max(p.criado_em) filter (where p.status in ('pago','entregue')) as ultima
    from pedidos_loja p
    where p.usuario = p_usuario
      and coalesce(trim(p.cliente->>'email'), '') <> ''
    group by 1
  ),
  inscritos as (
    select lower(trim(m.email)) as email,
           (array_agg(m.nome order by m.criado_em desc))[1] as nome
    from mensagens_loja m
    where m.usuario = p_usuario
      and m.tipo = 'novidades'
      and m.saiu_em is null
      and coalesce(trim(m.email), '') <> ''
    group by 1
  ),
  -- Tudo qualificado de proposito. Em returns table os nomes de saida
  -- viram variaveis visiveis aqui dentro, e um "email" solto sairia como
  -- referencia ambigua na hora de criar a funcao.
  todos as (
    select cc.email from compras cc
    union
    select ii.email from inscritos ii
  )
  select
    t.email                                                   as email,
    coalesce(c.nome, i.nome, '')                              as nome,
    coalesce(c.telefone, '')                                  as telefone,
    coalesce(c.pedidos, 0)::integer                           as pedidos,
    round(coalesce(c.gasto, 0), 2)                            as gasto,
    -- Ticket medio so faz sentido para quem ja comprou.
    case when coalesce(c.pedidos, 0) > 0
         then round(c.gasto / c.pedidos, 2)
         else 0 end                                           as ticket,
    coalesce(c.em_aberto, 0)::integer                         as em_aberto,
    c.primeira                                                as primeira_compra,
    c.ultima                                                  as ultima_compra,
    (i.email is not null)                                     as novidades,
    (select count(*) from cupons k
      where k.usuario = p_usuario
        and lower(k.email) = t.email
        and k.ativo
        and (k.expira_em is null or k.expira_em >= current_date)
        and (k.usos_max is null or k.usos < k.usos_max))::integer as cupons_ativos
  from todos t
  left join compras   c on c.email = t.email
  left join inscritos i on i.email = t.email
  order by coalesce(c.gasto, 0) desc, t.email;
$$;

grant execute on function public.clientes_loja(uuid) to authenticated;

-- ------------------------------------------------------------
--  Conferencia
-- ------------------------------------------------------------
-- A lista, como o Precifica vai ver:
--   select * from public.clientes_loja(auth.uid());
--
-- Um cupom pessoal na mao, se quiser testar antes:
--   insert into public.cupons (usuario, codigo, tipo, valor, email,
--                              usos_max, descricao)
--   values (auth.uid(), 'TESTE10', 'percentual', 10, 'alguem@exemplo.com',
--           1, 'teste de cupom pessoal');
--
-- E a funcao recusando para quem nao e o dono:
--   select public.valida_cupom(auth.uid(), 'TESTE10', 100, 'outro@exemplo.com');
