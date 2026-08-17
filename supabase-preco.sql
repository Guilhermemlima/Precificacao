-- ============================================================
--  Moldarte 3D · conserta a divergência de preço
--
--  Rode DEPOIS de supabase-cupons.sql, no SQL Editor.
--  Pode rodar mais de uma vez sem estragar nada.
--
--  O PROBLEMA
--  A loja mostrava um valor e o Asaas cobrava outro. Exemplo real
--  do catálogo: o Pernalonga tem preço 89,00 publicado, mas a
--  primeira faixa de quantidade ficou em 89,90. A loja aplicava o
--  desconto por volume usando a primeira faixa como referência, e o
--  banco usava o preço base — duas contas, dois resultados.
--
--    quantidade 1  → tela R$  89,00   cobrança R$  89,90
--    quantidade 3  → tela R$ 252,15   cobrança R$ 254,70
--    quantidade 10 → tela R$ 741,50   cobrança R$ 749,00
--
--  A CORREÇÃO
--  Faixa de uma unidade não muda preço — uma unidade custa o preço
--  publicado, ponto. Só faixas a partir de duas unidades aplicam
--  desconto. Assim o valor deixa de depender de a primeira faixa
--  concordar ou não com o preço base, e vale para o que já está
--  publicado sem precisar republicar nada.
-- ============================================================

create or replace function public.criar_pedido(
  p_usuario            uuid,
  p_id                 text,
  p_cliente            jsonb,
  p_entrega            jsonb,
  p_itens              jsonb,
  p_pagamento          text,
  p_observacoes        text,
  p_horas_reserva      integer default 24,
  p_cupom              text default null,
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
  v_slug      text;
  v_qtd       integer;
  v_tam       text;
  v_base      numeric(10,2);
  v_unit      numeric(10,2);
  v_faixa     jsonb;
  v_tamanho   jsonb;
  v_itens     jsonb := '[]'::jsonb;
  v_subtotal  numeric(10,2) := 0;
  v_frete     numeric(10,2) := 0;
  v_desconto  numeric(10,2) := 0;
  v_cupom     jsonb;
  v_cupom_cod text;
  v_disp      integer;
begin
  perform expirar_reservas(p_usuario);

  if jsonb_array_length(coalesce(p_itens, '[]'::jsonb)) = 0 then
    return jsonb_build_object('ok', false, 'erro', 'carrinho_vazio');
  end if;

  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_slug := v_item->>'slug';
    v_qtd  := greatest(1, coalesce((v_item->>'quantidade')::int, 1));
    v_tam  := v_item->>'tamanho';

    -- Trava a linha do produto: dois pedidos ao mesmo tempo entram em
    -- fila, em vez de os dois levarem a última peça.
    select * into v_linha
      from dados
     where usuario = p_usuario and colecao = 'loja' and id = v_slug
       and coalesce(apagado, false) = false
     for update;

    if not found then
      return jsonb_build_object('ok', false, 'erro', 'produto_fora_do_ar', 'slug', v_slug);
    end if;

    v_conteudo := v_linha.conteudo;

    if coalesce(v_conteudo->>'modo', '') = 'consulta' then
      return jsonb_build_object('ok', false, 'erro', 'produto_sob_consulta',
                                'nome', v_conteudo->>'nome');
    end if;

    v_base := coalesce((v_conteudo->>'preco')::numeric, 0);
    v_unit := v_base;

    -- Adicional do tamanho escolhido.
    if v_tam is not null then
      select t into v_tamanho
        from jsonb_array_elements(coalesce(v_conteudo->'tamanhos', '[]'::jsonb)) t
       where t->>'nome' = v_tam
       limit 1;
      if v_tamanho is not null then
        v_unit := coalesce((v_tamanho->>'preco')::numeric, v_unit);
      end if;
    end if;

    -- Desconto por quantidade.
    --
    -- Só faixas a partir de DUAS unidades. A faixa de uma unidade é só a
    -- linha "1 un — preço cheio" da tabela; quando ela discorda do preço
    -- base — e discorda, porque era arredondada na publicação — usá-la
    -- fazia a cobrança sair diferente do que a loja mostrou.
    select t into v_faixa
      from jsonb_array_elements(coalesce(v_conteudo->'faixas', '[]'::jsonb)) t
     where coalesce((t->>'qtd')::int, 1) <= v_qtd
       and coalesce((t->>'qtd')::int, 1) > 1
     order by (t->>'qtd')::int desc limit 1;

    if v_faixa is not null and v_base > 0 then
      v_unit := round(v_unit * (coalesce((v_faixa->>'preco')::numeric, v_base) / v_base), 2);
    end if;

    -- Estoque disponível de agora.
    select disponivel into v_disp
      from estoque_disponivel(p_usuario)
     where slug = v_slug;

    if coalesce(v_disp, 0) < v_qtd then
      return jsonb_build_object('ok', false, 'erro', 'estoque_insuficiente',
                                'slug', v_slug, 'nome', v_conteudo->>'nome',
                                'disponivel', coalesce(v_disp, 0));
    end if;

    v_subtotal := v_subtotal + (v_unit * v_qtd);

    v_itens := v_itens || jsonb_build_object(
      'slug', v_slug, 'nome', v_conteudo->>'nome',
      'tamanho', v_item->>'tamanho', 'opcoes', v_item->'opcoes',
      'quantidade', v_qtd, 'precoUnitario', v_unit,
      'total', round(v_unit * v_qtd, 2)
    );

    insert into estoque_movimento (usuario, slug, quantidade, motivo, pedido_id)
    values (p_usuario, v_slug, -v_qtd, 'reserva', p_id);
  end loop;

  -- Frete: a loja informa a tabela, a conta é feita aqui.
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
      -- Cupom recusado derruba o pedido de propósito: cobrar sem o desconto
      -- que a tela prometeu seria pior do que pedir para tentar de novo.
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
end;
$$;

grant execute on function public.criar_pedido(uuid, text, jsonb, jsonb, jsonb, text, text, integer, text, numeric, numeric) to authenticated;

-- ------------------------------------------------------------
--  Conferência
-- ------------------------------------------------------------
-- Os preços que a loja publicou, para comparar com a tela:
--   select id,
--          (conteudo->>'preco')::numeric               as preco_base,
--          conteudo->'faixas'->0->>'preco'             as primeira_faixa
--     from public.dados
--    where colecao = 'loja' and coalesce(apagado,false) = false;
--
-- Depois da correção, preco_base é o que vale para uma unidade,
-- concorde ou não com primeira_faixa.
