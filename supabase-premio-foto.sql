-- ============================================================
--  Moldarte 3D · cupom de agradecimento por foto
--
--  Rode DEPOIS de supabase-fotos-avaliacao.sql, no SQL Editor.
--  Pode rodar mais de uma vez sem estragar nada.
--
--  Quando voce aprova uma avaliacao que veio com foto, o cliente
--  ganha um cupom para a proxima compra. A coluna abaixo guarda
--  qual cupom foi gerado — e e ela que impede gerar dois para a
--  mesma avaliacao se voce aprovar, tirar do ar e aprovar de novo.
-- ============================================================

alter table public.avaliacoes
  add column if not exists cupom text;

-- ------------------------------------------------------------
--  Conferencia
-- ------------------------------------------------------------
-- select id, slug, nota, aprovada, cupom,
--        jsonb_array_length(coalesce(fotos,'[]'::jsonb)) as fotos
--   from public.avaliacoes order by criado_em desc;
--
-- Os cupons gerados por foto:
--   select codigo, tipo, valor, usos, usos_max, expira_em, descricao
--     from public.cupons where descricao like '%foto%' order by criado_em desc;
