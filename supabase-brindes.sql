-- ============================================================
--  Moldarte 3D · pedidos de empresa (brindes e chaveiros)
--
--  Rode quando quiser, em qualquer ponto depois do
--  supabase-orcamentos.sql. Ele so acrescenta colunas: nao mexe
--  em funcao nenhuma, entao nao briga com os outros arquivos e
--  pode rodar mais de uma vez.
--
--  POR QUE
--  A pagina de brindes recebe pedido de empresa, e empresa traz
--  duas coisas que pessoa fisica nao tem: razao social e CNPJ.
--  Sem lugar proprio, isso ia junto no texto da descricao — e a
--  primeira coisa que voce precisa saber ao abrir o orcamento
--  ("de quem e essa empresa?") ficaria perdida no meio do
--  paragrafo.
--
--  A coluna origem separa o que veio da pagina de brindes do que
--  veio do orcamento comum. Sao conversas diferentes: uma pede
--  proposta com prazo de evento e quantidade, a outra e uma peca
--  so.
-- ============================================================

alter table public.orcamentos_loja
  add column if not exists empresa   text,
  add column if not exists documento text,
  add column if not exists origem    text not null default 'site';

comment on column public.orcamentos_loja.empresa is
  'Razao social ou nome fantasia, quando o pedido vem de empresa.';
comment on column public.orcamentos_loja.documento is
  'CNPJ (ou CPF) informado no pedido de brindes. So digitos.';
comment on column public.orcamentos_loja.origem is
  'De onde veio: site (orcamento comum) ou brindes (pagina de empresas).';

-- Para separar rapido os pedidos de empresa na hora de olhar.
create index if not exists orcamentos_loja_origem_idx
  on public.orcamentos_loja (usuario, origem, criado_em desc);

-- ------------------------------------------------------------
--  Conferencia
-- ------------------------------------------------------------
-- As colunas entraram?
--   select column_name from information_schema.columns
--    where table_name = 'orcamentos_loja'
--      and column_name in ('empresa','documento','origem');
--
-- Os pedidos de empresa que chegaram:
--   select id, empresa, documento, quantidade, criado_em
--     from public.orcamentos_loja
--    where origem = 'brindes'
--    order by criado_em desc;
