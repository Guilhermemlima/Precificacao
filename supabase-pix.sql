-- ============================================================
--  Moldarte 3D · o desconto do Pix passa a existir
--
--  Rode DEPOIS de supabase-preco.sql. Este arquivo passa a ser o
--  ULTIMO da lista. Pode rodar mais de uma vez.
--
--  O PROBLEMA
--  A loja anunciava "5% de desconto no Pix" na pagina do produto,
--  no resumo do carrinho e na escolha de pagamento — e mostrava o
--  total ja com o desconto. So que o desconto nao existia em lugar
--  nenhum: o pedido era gravado pelo valor cheio e o Asaas cobrava
--  o valor cheio. O cliente via um numero no site e outro na hora
--  de pagar, que e exatamente a divergencia que este projeto ja
--  tinha consertado uma vez.
--
--  A CORRECAO
--  O desconto vira conta de verdade, aqui, que e onde o total do
--  pedido nasce. A taxa chega da loja (p_desconto_pix), e so vale
--  quando o pagamento escolhido e Pix. Incide sobre a mercadoria
--  ja com o cupom, nunca sobre o frete.
--
--  A funcao abaixo e a do supabase-preco.sql recortada linha por
--  linha, com as poucas linhas do Pix somadas. Nao foi redigitada:
--  reescrever a mao uma funcao que funciona ja custou caro aqui uma
--  vez, quando o nome de uma coluna do estoque saiu trocado e todo
--  pedido passou a ser recusado.
-- ============================================================

-- Guardado separado do desconto do cupom: sao duas coisas
-- diferentes, e junta-las esconderia qual delas voce deu.
alter table public.pedidos_loja
  add column if not exists desconto_pix numeric(10,2) default 0;

-- A versao antiga tinha 11 parametros; a nova tem 12. Sem apagar a
-- antiga, as duas ficariam vivas ao mesmo tempo e o banco poderia
-- escolher a de sempre — o desconto sumiria de novo, so que agora
-- de um jeito dificil de enxergar.
drop function if exists public.criar_pedido(
  uuid, text, jsonb, jsonb, jsonb, text, text, integer, text, numeric, numeric
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
--  Conferencia
-- ------------------------------------------------------------
-- A funcao existe com os 12 parametros?
--   select pg_get_function_identity_arguments(oid)
--     from pg_proc where proname = 'criar_pedido';
--
-- Os ultimos pedidos, com o desconto separado:
--   select id, pagamento, subtotal, desconto, desconto_pix, frete, total
--     from public.pedidos_loja order by criado_em desc limit 10;
