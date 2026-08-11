-- ============================================================
--  Precifica 3D → Loja Moldarte 3D
--  Publicação de produtos para um site externo.
--
--  Rode este arquivo UMA VEZ no SQL Editor do seu projeto,
--  DEPOIS de já ter rodado o supabase-schema.sql.
--  (Supabase → SQL Editor → New query → cole tudo → Run)
-- ============================================================

-- ------------------------------------------------------------
--  Por que uma coleção separada, e não abrir o catálogo
--
--  O catálogo sincroniza como UM documento só (colecao='catalogo',
--  com a lista inteira de categorias e produtos dentro). Liberar a
--  leitura pública dele exporia também o que não foi publicado:
--  rascunhos, preços em estudo, produtos fora do ar.
--
--  Por isso, publicar grava UMA LINHA POR PRODUTO em colecao='loja',
--  contendo só o que a vitrine precisa mostrar. A regra abaixo abre
--  exatamente essa coleção — e nada mais. Pedidos, rolos de
--  filamento, configurações e clientes continuam trancados.
-- ------------------------------------------------------------

drop policy if exists "loja e publica" on public.dados;
create policy "loja e publica" on public.dados
  for select
  to anon, authenticated
  using (colecao = 'loja' and not apagado);

comment on policy "loja e publica" on public.dados is
  'Leitura sem login apenas dos produtos publicados na loja. Nenhuma outra colecao e exposta.';

-- Deixa a listagem da vitrine rápida mesmo com o catálogo crescendo.
create index if not exists dados_loja_idx
  on public.dados (colecao, apagado)
  where colecao = 'loja';

-- ------------------------------------------------------------
--  Espaço das fotos
--
--  As fotos do catálogo hoje trafegam dentro do banco, em base64.
--  Isso funciona para o app, mas pesa numa vitrine: cada foto viaja
--  junto com os dados e não passa por cache de CDN. Aqui elas ganham
--  um balde próprio, público para leitura e restrito para escrita.
-- ------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'loja',
  'loja',
  true,
  5242880,                                   -- 5 MB por arquivo
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Qualquer pessoa vê as fotos (é uma vitrine, elas são públicas por natureza).
drop policy if exists "fotos da loja sao publicas" on storage.objects;
create policy "fotos da loja sao publicas" on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'loja');

-- Escrever, trocar e apagar: só o dono, e só dentro da própria pasta.
-- O caminho é <id-do-usuario>/produtos/<arquivo>, então a primeira
-- pasta do caminho precisa bater com quem está logado.
drop policy if exists "dono envia foto da loja" on storage.objects;
create policy "dono envia foto da loja" on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'loja'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "dono troca foto da loja" on storage.objects;
create policy "dono troca foto da loja" on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'loja'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "dono apaga foto da loja" on storage.objects;
create policy "dono apaga foto da loja" on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'loja'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ------------------------------------------------------------
--  Conferência: o que a vitrine enxerga
--
--  Depois de publicar algum produto, rode a consulta abaixo para ver
--  exatamente o que um visitante anônimo receberia.
-- ------------------------------------------------------------
create or replace view public.vitrine
with (security_invoker = true) as
select
  id                                     as slug,
  usuario,
  conteudo->>'nome'                      as nome,
  conteudo->>'categoria'                 as categoria,
  conteudo->>'modo'                      as modo,
  (conteudo->>'preco')::numeric          as preco,
  conteudo->>'foto'                      as foto,
  (conteudo->>'prazoDias')::int          as prazo_dias,
  (conteudo->>'estoque')::int            as estoque,
  atualizado_em
from public.dados
where colecao = 'loja' and not apagado;

comment on view public.vitrine is
  'Os produtos publicados, em colunas. Mesma visibilidade da politica "loja e publica".';

-- ------------------------------------------------------------
--  O que a loja precisa saber para consultar
--
--  Rode isto e guarde o resultado: é o identificador da sua conta.
--  Ele vai na variável NEXT_PUBLIC_SUPABASE_OWNER do site, para a
--  vitrine mostrar só os SEUS produtos caso outra pessoa venha a
--  usar o Precifica no mesmo projeto.
--
--    select id, email from auth.users;
-- ------------------------------------------------------------
