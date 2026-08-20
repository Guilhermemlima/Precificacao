-- ============================================================
--  Moldarte 3D · fotos nas avaliações
--
--  Rode DEPOIS de supabase-avisos.sql, no SQL Editor.
--  Pode rodar mais de uma vez sem estragar nada.
--
--  Foto de cliente com a peça na mão é a prova social mais forte
--  que existe — e vira acervo para usar no Instagram depois.
-- ============================================================

alter table public.avaliacoes
  -- [{ caminho, largura, altura }] — a imagem em si mora no balde.
  add column if not exists fotos jsonb not null default '[]'::jsonb;

-- ------------------------------------------------------------
--  Balde das fotos de avaliação
--
--  PÚBLICO, ao contrário do balde dos orçamentos. Estas fotos são
--  feitas para aparecer na página do produto — se fossem privadas,
--  cada visitante precisaria de um link assinado para ver.
--
--  Só a chave de serviço escreve, e só depois de conferir que quem
--  está mandando tem a chave de um pedido de verdade.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avaliacoes',
  'avaliacoes',
  true,
  5242880,                                   -- 5 MB por foto
  array['image/jpeg','image/png','image/webp','image/heic']
)
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "fotos de avaliacao sao publicas" on storage.objects;
create policy "fotos de avaliacao sao publicas" on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'avaliacoes');

-- Apagar: só o dono, para tirar do ar uma foto que não devia estar lá.
drop policy if exists "dono apaga foto de avaliacao" on storage.objects;
create policy "dono apaga foto de avaliacao" on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'avaliacoes'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Não existe política de INSERT: quem escreve é o site, pelo
-- servidor. Ninguém logado no app precisa subir foto aqui.

-- ------------------------------------------------------------
--  Conferência
-- ------------------------------------------------------------
-- select id, public, file_size_limit from storage.buckets where id = 'avaliacoes';
-- select column_name from information_schema.columns
--  where table_name = 'avaliacoes' and column_name = 'fotos';
