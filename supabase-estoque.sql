-- ============================================================
--  Precifica 3D → Loja Moldarte 3D
--  Pedidos da loja e controle automático de estoque.
--
--  Rode UMA VEZ no SQL Editor, depois do supabase-schema.sql e
--  do supabase-loja.sql.
-- ============================================================

-- ------------------------------------------------------------
--  Por que um extrato, e não um número
--
--  O estoque não pode ser um campo que os dois lados escrevem. O
--  catálogo do Precifica sobe como documento inteiro e vence o
--  mais recente: se a loja baixasse o número direto, a próxima
--  sincronização apagaria a venda.
--
--  Então a quantidade publicada no Precifica é a BASE, e cada
--  venda vira uma LINHA neste extrato. O disponível é a base mais
--  a soma das linhas. Ninguém sobrescreve ninguém, e de brinde
--  fica o histórico de quando cada peça saiu.
-- ------------------------------------------------------------
create table if not exists public.estoque_movimento (
  id         bigserial   primary key,
  usuario    uuid        not null references auth.users(id) on delete cascade,
  slug       text        not null,
  delta      integer     not null,
  motivo     text        not null,          -- venda, cancelamento, expiracao, ajuste
  pedido_id  text,
  criado_em  timestamptz not null default now()
);

create index if not exists estoque_movimento_idx
  on public.estoque_movimento (usuario, slug, criado_em desc);

comment on table public.estoque_movimento is
  'Cada linha muda o estoque de uma peca. Negativo sai, positivo volta.';

alter table public.estoque_movimento enable row level security;

-- O dono enxerga o próprio extrato. Ninguém mais: quantas peças
-- saíram e quando é informação de negócio, não de vitrine.
drop policy if exists "dono le o extrato" on public.estoque_movimento;
create policy "dono le o extrato" on public.estoque_movimento
  for select using (usuario = auth.uid());

-- ------------------------------------------------------------
--  Pedidos vindos do site
-- ------------------------------------------------------------
create table if not exists public.pedidos_loja (
  id          text        primary key,
  usuario     uuid        not null references auth.users(id) on delete cascade,
  status      text        not null default 'reservado',   -- reservado, pago, cancelado, expirado
  cliente     jsonb       not null default '{}'::jsonb,
  entrega     jsonb       not null default '{}'::jsonb,
  itens       jsonb       not null default '[]'::jsonb,
  subtotal    numeric(10,2) not null default 0,
  frete       numeric(10,2) not null default 0,
  total       numeric(10,2) not null default 0,
  pagamento   text,
  observacoes text,
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz,
  -- Marca que o Precifica já trouxe este pedido para a aba Pedidos,
  -- para não duplicar a cada sincronização.
  importado   boolean     not null default false
);

create index if not exists pedidos_loja_idx
  on public.pedidos_loja (usuario, criado_em desc);

alter table public.pedidos_loja enable row level security;

-- Só o dono lê e altera. O site nunca fala direto com esta tabela:
-- ele passa pela função abaixo, do lado do servidor.
drop policy if exists "dono le pedidos da loja" on public.pedidos_loja;
create policy "dono le pedidos da loja" on public.pedidos_loja
  for select using (usuario = auth.uid());

drop policy if exists "dono altera pedidos da loja" on public.pedidos_loja;
create policy "dono altera pedidos da loja" on public.pedidos_loja
  for update using (usuario = auth.uid()) with check (usuario = auth.uid());

-- ------------------------------------------------------------
--  Reservas vencidas voltam para o estoque
--
--  Pedido feito e não pago em 24 horas devolve a peça à prateleira.
--  Sem isso, um pedido abandonado — ou de má-fé — travaria o
--  estoque para sempre.
-- ------------------------------------------------------------
create or replace function public.expirar_reservas(p_usuario uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido record;
  v_item   jsonb;
  v_qtd    integer := 0;
begin
  for v_pedido in
    select * from pedidos_loja
    where usuario = p_usuario
      and status = 'reservado'
      and expira_em is not null
      and expira_em < now()
    for update
  loop
    for v_item in select * from jsonb_array_elements(v_pedido.itens) loop
      insert into estoque_movimento (usuario, slug, delta, motivo, pedido_id)
      values (p_usuario,
              v_item->>'slug',
              (v_item->>'quantidade')::int,
              'expiracao',
              v_pedido.id);
    end loop;

    update pedidos_loja set status = 'expirado' where id = v_pedido.id;
    v_qtd := v_qtd + 1;
  end loop;

  return v_qtd;
end $$;

-- ------------------------------------------------------------
--  Quanto ainda tem de cada peça
--
--  Base publicada + soma dos movimentos feitos DEPOIS de a base ter
--  sido definida. É o "depois" que permite você corrigir o estoque
--  no Precifica: ao digitar 10, a conta recomeça do 10, sem as
--  vendas antigas descontando de novo.
-- ------------------------------------------------------------
create or replace function public.estoque_disponivel(p_usuario uuid)
returns table(slug text, disponivel integer)
language sql
stable
security definer
set search_path = public
as $$
  select
    d.id as slug,
    greatest(0,
      coalesce((d.conteudo->>'estoque')::int, 0)
      + coalesce((
          select sum(m.delta)::int
          from estoque_movimento m
          where m.usuario = d.usuario
            and m.slug = d.id
            and m.criado_em >= coalesce(
                  (d.conteudo->>'estoqueDefinidoEm')::timestamptz,
                  '-infinity'::timestamptz)
        ), 0)
    ) as disponivel
  from dados d
  where d.colecao = 'loja'
    and not d.apagado
    and d.usuario = p_usuario;
$$;

-- A vitrine precisa desta contagem sem login. Ela devolve só
-- "peça X tem N" — que é exatamente o que a loja já mostra.
grant execute on function public.estoque_disponivel(uuid) to anon, authenticated;

-- ------------------------------------------------------------
--  Criar pedido: preço conferido, estoque travado
--
--  Tudo numa transação só. O `for update` na linha da peça faz dois
--  pedidos simultâneos entrarem em fila em vez de os dois levarem a
--  última unidade.
--
--  O preço NÃO vem do navegador: é recalculado aqui a partir do que
--  está publicado. Sem isso, bastaria editar o carrinho para comprar
--  por um real.
-- ------------------------------------------------------------
create or replace function public.criar_pedido(
  p_usuario     uuid,
  p_id          text,
  p_cliente     jsonb,
  p_entrega     jsonb,
  p_itens       jsonb,      -- [{slug, quantidade, opcoes}]
  p_frete       numeric,
  p_pagamento   text,
  p_observacoes text,
  p_horas_reserva integer default 24
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
begin
  -- Antes de qualquer conta, devolve o que venceu.
  perform expirar_reservas(p_usuario);

  if jsonb_array_length(p_itens) = 0 then
    return jsonb_build_object('ok', false, 'erro', 'carrinho_vazio');
  end if;

  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_qtd := greatest(1, coalesce((v_item->>'quantidade')::int, 1));

    -- Trava a peça: dois pedidos ao mesmo tempo viram fila.
    select * into v_linha
    from dados
    where usuario = p_usuario
      and colecao = 'loja'
      and id = v_item->>'slug'
      and not apagado
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
    from estoque_disponivel(p_usuario) e
    where e.slug = v_linha.id;

    if coalesce(v_disp, 0) < v_qtd then
      return jsonb_build_object('ok', false, 'erro', 'estoque_insuficiente',
                                'slug', v_linha.id,
                                'nome', v_conteudo->>'nome',
                                'disponivel', coalesce(v_disp, 0));
    end if;

    -- Preço pelo banco: base + adicional do tamanho escolhido.
    v_base := coalesce((v_conteudo->>'preco')::numeric, 0);
    v_adicional := 0;

    if v_item ? 'tamanho' and coalesce(v_item->>'tamanho', '') <> '' then
      select coalesce((t->>'adicional')::numeric, 0) into v_adicional
      from jsonb_array_elements(coalesce(v_conteudo->'tamanhos', '[]'::jsonb)) t
      where t->>'nome' = v_item->>'tamanho'
      limit 1;
      v_adicional := coalesce(v_adicional, 0);
    end if;

    v_unit := v_base + v_adicional;

    -- Desconto por quantidade: a faixa é proporção sobre o preço cheio,
    -- para o desconto valer também no tamanho maior.
    select t into v_faixa
    from jsonb_array_elements(coalesce(v_conteudo->'faixas', '[]'::jsonb)) t
    where coalesce((t->>'qtd')::int, 1) <= v_qtd
    order by (t->>'qtd')::int desc
    limit 1;

    if v_faixa is not null and v_base > 0 then
      v_unit := round(v_unit * (coalesce((v_faixa->>'preco')::numeric, v_base) / v_base), 2);
    end if;

    v_subtotal := v_subtotal + (v_unit * v_qtd);

    v_itens := v_itens || jsonb_build_object(
      'slug', v_linha.id,
      'nome', v_conteudo->>'nome',
      'tamanho', v_item->>'tamanho',
      'opcoes', v_item->'opcoes',
      'quantidade', v_qtd,
      'precoUnitario', v_unit,
      'total', round(v_unit * v_qtd, 2)
    );

    insert into estoque_movimento (usuario, slug, delta, motivo, pedido_id)
    values (p_usuario, v_linha.id, -v_qtd, 'venda', p_id);
  end loop;

  insert into pedidos_loja (id, usuario, status, cliente, entrega, itens,
                            subtotal, frete, total, pagamento, observacoes, expira_em)
  values (p_id, p_usuario, 'reservado', p_cliente, p_entrega, v_itens,
          round(v_subtotal, 2), coalesce(p_frete, 0),
          round(v_subtotal + coalesce(p_frete, 0), 2),
          p_pagamento, p_observacoes,
          now() + make_interval(hours => greatest(1, p_horas_reserva)));

  return jsonb_build_object('ok', true, 'id', p_id, 'itens', v_itens,
                            'subtotal', round(v_subtotal, 2),
                            'total', round(v_subtotal + coalesce(p_frete, 0), 2));
end $$;

-- Só o servidor da loja chama esta função, com a chave service_role.
-- Ninguém anônimo pode criar pedido direto.
revoke execute on function public.criar_pedido(uuid, text, jsonb, jsonb, jsonb, numeric, text, text, integer) from anon;

-- ------------------------------------------------------------
--  Cancelar um pedido devolve as peças
-- ------------------------------------------------------------
create or replace function public.cancelar_pedido(p_usuario uuid, p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido record;
  v_item   jsonb;
begin
  select * into v_pedido from pedidos_loja
  where id = p_id and usuario = p_usuario for update;

  if not found then
    return jsonb_build_object('ok', false, 'erro', 'pedido_nao_encontrado');
  end if;

  -- Já cancelado ou vencido: as peças voltaram, não devolve duas vezes.
  if v_pedido.status in ('cancelado', 'expirado') then
    return jsonb_build_object('ok', true, 'ja_estava', v_pedido.status);
  end if;

  for v_item in select * from jsonb_array_elements(v_pedido.itens) loop
    insert into estoque_movimento (usuario, slug, delta, motivo, pedido_id)
    values (p_usuario, v_item->>'slug', (v_item->>'quantidade')::int,
            'cancelamento', v_pedido.id);
  end loop;

  update pedidos_loja set status = 'cancelado' where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.cancelar_pedido(uuid, text) to authenticated;
grant execute on function public.expirar_reservas(uuid) to authenticated;

-- ------------------------------------------------------------
--  Conferência
--
--    select * from public.estoque_disponivel(auth.uid());
--    select id, status, total, expira_em from public.pedidos_loja order by criado_em desc;
--    select * from public.estoque_movimento order by criado_em desc limit 20;
-- ------------------------------------------------------------
