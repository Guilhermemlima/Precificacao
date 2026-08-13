-- ============================================================
--  Precifica 3D → Loja Moldarte 3D
--  Pagamento pelo Asaas.
--
--  Rode UMA VEZ no SQL Editor, depois do supabase-estoque.sql.
-- ============================================================

-- ------------------------------------------------------------
--  O pedido passa a lembrar qual cobrança é a dele
--
--  `pagamento_id` é o identificador que o Asaas devolve ao criar a
--  cobrança. É por ele que o aviso de "pagou" encontra o pedido
--  certo quando chega — o Asaas não conhece a nossa numeração.
--
--  `pagamento_url` é a página onde o cliente paga. Guardada para
--  você conseguir reenviar o link por WhatsApp se ele fechar a aba
--  antes de terminar.
-- ------------------------------------------------------------
alter table public.pedidos_loja
  add column if not exists pagamento_id  text,
  add column if not exists pagamento_url text,
  add column if not exists pago_em       timestamptz;

-- O aviso do Asaas chega com o identificador da cobrança e nada mais.
-- Sem este índice, cada aviso varreria a tabela inteira.
create unique index if not exists pedidos_loja_pagamento_idx
  on public.pedidos_loja (pagamento_id)
  where pagamento_id is not null;

comment on column public.pedidos_loja.pagamento_id is
  'Identificador da cobranca no Asaas. Liga o aviso de pagamento ao pedido.';

-- ------------------------------------------------------------
--  Pedido pago não expira
--
--  A reserva de 24 horas existe para pedido que ninguem pagou. Uma
--  vez confirmado o pagamento, o estoque ja saiu de vez e o pedido
--  nao pode mais voltar para a prateleira.
--
--  A funcao de expirar so olha status = 'reservado', entao marcar
--  como 'pago' ja resolve. Este comentario fica aqui para a regra
--  nao se perder de vista quando alguem mexer no prazo.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
--  Conferência
--
--    select id, status, total, pagamento_id, pago_em
--    from public.pedidos_loja order by criado_em desc;
-- ------------------------------------------------------------
