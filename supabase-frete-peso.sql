-- ============================================================
--  Moldarte 3D · frete por peso
--
--  Rode DEPOIS de supabase-clientes.sql. Este arquivo passa a ser
--  o ULTIMO da fila. Pode rodar mais de uma vez.
--
--  O PROBLEMA
--  A loja cobrava um valor por regiao, igual para tudo. Um valor
--  so esta errado nas duas pontas: o chaveiro de 40 g pagava
--  frete de vaso — e frete alto e o motivo numero um de carrinho
--  abandonado —, enquanto o vaso de 900 g saia barato demais, com
--  a diferenca vindo do lucro.
--
--  A CORRECAO
--  A loja passa a mandar a tabela de faixas da regiao, e quem
--  escolhe a faixa e esta funcao, somando o peso das pecas a
--  partir do que esta publicado no banco. O peso nunca vem do
--  navegador: se viesse, bastaria edita-lo para pagar o frete
--  mais barato, do mesmo jeito que ja aconteceu com o valor do
--  frete antes de ele passar a ser calculado aqui.
--
--  Peca sem peso cadastrado usa o padrao que a loja manda, nunca
--  zero — zero jogaria toda peca antiga na faixa mais barata e o
--  prejuizo sairia calado.
--
--  A funcao abaixo e a do supabase-clientes.sql recortada linha a
--  linha, com as linhas do peso somadas. Nao foi redigitada:
--  reescrever a mao uma funcao que funciona ja custou caro aqui.
-- ============================================================

-- Guardado no pedido para dar para conferir depois por que o
-- frete saiu naquele valor.
alter table public.pedidos_loja
  add column if not exists peso_gramas integer;

-- A versao anterior tinha 12 parametros; esta tem 15. Sem apagar
-- a antiga, as duas ficariam vivas ao mesmo tempo e o banco
-- poderia escolher a de sempre — o frete voltaria a ser um valor
-- unico, so que agora de um jeito dificil de enxergar.
drop function if exists public.criar_pedido(
  uuid, text, jsonb, jsonb, jsonb, text, text, integer, text, numeric, numeric, numeric
);

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
  -- Faixas de frete desta regiao, do mais leve para o mais pesado:
  -- [{"ate": 300, "valor": 23.90}, ...]. A loja manda a tabela; quem
  -- escolhe a faixa e aqui, com o peso somado das pecas do banco.
  p_frete_faixas       jsonb   default '[]'::jsonb,
  p_frete_padrao       numeric default 0,
  p_frete_gratis_acima numeric default 0,
  -- Percentual de desconto no Pix. Quem manda a taxa e a loja, para o valor
  -- morar num lugar so; aqui so se aplica se o pagamento escolhido for Pix.
  p_desconto_pix       numeric default 0,
  -- Peso usado quando a peca ainda nao tem o dela cadastrado. Zero faria
  -- toda peca antiga cair na faixa mais barata, e a diferenca sairia do
  -- lucro sem ninguem perceber.
  p_peso_padrao        integer default 300,
  -- Quanto a embalagem soma ao pacote fechado.
  p_peso_embalagem     integer default 60
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
  v_peso      integer := 0;
  v_peso_item integer;
  v_faixa_frete jsonb;
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

    -- Peso do tamanho escolhido; sem tamanho, o da peca; sem nenhum dos
    -- dois, o padrao. Nunca zero: peca sem peso viajaria de graca.
    v_peso_item := null;

    if v_item ? 'tamanho' and coalesce(v_item->>'tamanho', '') <> '' then
      select nullif((t->>'pesoGramas')::numeric, 0)::int into v_peso_item
      from jsonb_array_elements(coalesce(v_conteudo->'tamanhos', '[]'::jsonb)) t
      where t->>'nome' = v_item->>'tamanho' limit 1;
    end if;

    v_peso_item := coalesce(
      v_peso_item,
      nullif((v_conteudo->>'pesoGramas')::numeric, 0)::int,
      p_peso_padrao
    );

    v_peso := v_peso + (v_peso_item * v_qtd);

    v_itens := v_itens || jsonb_build_object(
      'slug', v_linha.id, 'nome', v_conteudo->>'nome',
      'tamanho', v_item->>'tamanho', 'opcoes', v_item->'opcoes',
      'quantidade', v_qtd, 'precoUnitario', v_unit,
      'total', round(v_unit * v_qtd, 2)
    );

    insert into estoque_movimento (usuario, slug, delta, motivo, pedido_id)
    values (p_usuario, v_linha.id, -v_qtd, 'venda', p_id);
  end loop;

  -- Frete pela tabela da loja, nunca pelo que veio da tela. Agora ele
  -- depende de duas coisas: a regiao (que ja veio escolhida na tabela de
  -- faixas) e o peso do pacote fechado, somado aqui a partir das pecas.
  if jsonb_array_length(coalesce(p_frete_faixas, '[]'::jsonb)) > 0 then
    v_peso := v_peso + coalesce(p_peso_embalagem, 0);

    -- A primeira faixa que cobre o peso. Acima da ultima, vale a ultima:
    -- mais de um quilo e caso raro, e inventar preco maior para um pacote
    -- que talvez nem custe mais afastaria o pedido grande.
    select t into v_faixa_frete
    from jsonb_array_elements(p_frete_faixas) t
    where (t->>'ate')::int >= v_peso
    order by (t->>'ate')::int asc limit 1;

    if v_faixa_frete is null then
      select t into v_faixa_frete
      from jsonb_array_elements(p_frete_faixas) t
      order by (t->>'ate')::int desc limit 1;
    end if;
  end if;

  v_frete := case
    when p_frete_gratis_acima > 0 and v_subtotal >= p_frete_gratis_acima then 0
    -- Sem tabela de faixas (chamada antiga), vale o valor unico de antes.
    else coalesce((v_faixa_frete->>'valor')::numeric, p_frete_padrao, 0)
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
                            expira_em, cupom, desconto, desconto_pix, peso_gramas)
  values (p_id, p_usuario, 'reservado', p_cliente, p_entrega, v_itens,
          round(v_subtotal, 2), v_frete,
          greatest(0, round(v_subtotal - v_desconto - v_pix + v_frete, 2)),
          p_pagamento, p_observacoes,
          now() + make_interval(hours => greatest(1, p_horas_reserva)),
          v_cupom_cod, v_desconto, v_pix, v_peso);

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'itens', v_itens,
    'subtotal', round(v_subtotal, 2),
    'desconto', v_desconto,
    'descontoPix', v_pix,
    'frete', v_frete,
    'pesoGramas', v_peso,
    'cupom', v_cupom_cod,
    'total', greatest(0, round(v_subtotal - v_desconto - v_pix + v_frete, 2))
  );
end $$;

revoke execute on function public.criar_pedido(uuid, text, jsonb, jsonb, jsonb, text, text, integer, text, jsonb, numeric, numeric, numeric, integer, integer) from anon;

-- ------------------------------------------------------------
--  Conferencia
-- ------------------------------------------------------------
-- A funcao existe com a tabela de faixas?
--   select pg_get_function_identity_arguments(oid)
--     from pg_proc where proname = 'criar_pedido';
--
-- Os ultimos pedidos, com o peso que decidiu o frete:
--   select id, peso_gramas, frete, subtotal, total
--     from public.pedidos_loja order by criado_em desc limit 10;
--
-- Quais pecas ainda estao sem peso publicado (elas usam o padrao):
--   select id, conteudo->>'nome' as nome
--     from public.dados
--    where colecao = 'loja' and not apagado
--      and coalesce((conteudo->>'pesoGramas')::numeric, 0) = 0;
