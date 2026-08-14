-- ============================================================
--  Moldarte 3D · pedidos de orçamento e mensagens do site
--
--  Rode este arquivo DEPOIS de supabase-cupons.sql, no SQL Editor
--  do Supabase. Ele pode ser rodado mais de uma vez sem estragar
--  nada: tudo é "create if not exists" ou "drop/create".
--
--  Por que isto existe: o formulário de orçamento do site mostrava
--  "recebemos seu projeto" e não gravava nada em lugar nenhum. O
--  STL ficava no navegador do cliente e sumia quando ele fechava a
--  aba. Aqui a solicitação passa a ter onde morar.
-- ============================================================

-- ------------------------------------------------------------
--  Pedidos de orçamento
--
--  Separado de pedidos_loja de propósito: um pedido tem preço,
--  estoque reservado e prazo correndo; um orçamento é uma conversa
--  que ainda não virou venda. Misturar os dois faria a lista de
--  vendas mentir.
-- ------------------------------------------------------------
create table if not exists public.orcamentos_loja (
  id          text        primary key,
  usuario     uuid        not null references auth.users(id) on delete cascade,
  status      text        not null default 'novo',   -- novo, respondido, fechado, perdido
  nome        text        not null,
  email       text,
  telefone    text,
  quantidade  integer     not null default 1,
  material    text,
  acabamento  text,
  prazo       text,
  descricao   text,
  -- [{ nome, caminho, tamanho, tipo }] — o arquivo em si mora no
  -- balde 'orcamentos', não aqui dentro.
  arquivos    jsonb       not null default '[]'::jsonb,
  criado_em   timestamptz not null default now(),
  -- Marca que o Precifica já trouxe este orçamento para a aba,
  -- para não duplicar a cada sincronização.
  importado   boolean     not null default false
);

create index if not exists orcamentos_loja_idx
  on public.orcamentos_loja (usuario, criado_em desc);

alter table public.orcamentos_loja enable row level security;

-- Só o dono lê e altera. O site escreve pelo servidor, com a chave
-- de serviço, que passa por cima destas regras — ninguém no
-- navegador chega perto desta tabela.
drop policy if exists "dono le orcamentos" on public.orcamentos_loja;
create policy "dono le orcamentos" on public.orcamentos_loja
  for select using (usuario = auth.uid());

drop policy if exists "dono altera orcamentos" on public.orcamentos_loja;
create policy "dono altera orcamentos" on public.orcamentos_loja
  for update using (usuario = auth.uid()) with check (usuario = auth.uid());

drop policy if exists "dono apaga orcamentos" on public.orcamentos_loja;
create policy "dono apaga orcamentos" on public.orcamentos_loja
  for delete using (usuario = auth.uid());

-- ------------------------------------------------------------
--  Mensagens de contato e cadastros de novidades
--
--  Mesma história: os dois formulários trocavam de tela sem enviar
--  nada. Uma tabela só, com uma coluna dizendo de onde veio, porque
--  a diferença entre eles é pequena demais para justificar duas.
-- ------------------------------------------------------------
create table if not exists public.mensagens_loja (
  id         bigint      generated always as identity primary key,
  usuario    uuid        not null references auth.users(id) on delete cascade,
  tipo       text        not null default 'contato',  -- contato, novidades
  nome       text,
  email      text,
  telefone   text,
  assunto    text,
  mensagem   text,
  lida       boolean     not null default false,
  criado_em  timestamptz not null default now()
);

create index if not exists mensagens_loja_idx
  on public.mensagens_loja (usuario, criado_em desc);

-- Um e-mail que se cadastra duas vezes nas novidades não vira duas
-- linhas. Só vale para 'novidades': a mesma pessoa pode mandar
-- várias mensagens de contato, e todas importam.
create unique index if not exists mensagens_loja_novidades_unicas
  on public.mensagens_loja (usuario, lower(email))
  where tipo = 'novidades';

alter table public.mensagens_loja enable row level security;

drop policy if exists "dono le mensagens" on public.mensagens_loja;
create policy "dono le mensagens" on public.mensagens_loja
  for select using (usuario = auth.uid());

drop policy if exists "dono altera mensagens" on public.mensagens_loja;
create policy "dono altera mensagens" on public.mensagens_loja
  for update using (usuario = auth.uid()) with check (usuario = auth.uid());

drop policy if exists "dono apaga mensagens" on public.mensagens_loja;
create policy "dono apaga mensagens" on public.mensagens_loja
  for delete using (usuario = auth.uid());

-- ------------------------------------------------------------
--  Balde dos arquivos de orçamento
--
--  PRIVADO, ao contrário do balde 'loja'. As fotos do catálogo são
--  uma vitrine; um STL enviado por um cliente é o projeto dele, e
--  às vezes o produto inteiro do negócio dele. Quem precisar ver
--  baixa por um link assinado, que vence.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values (
  'orcamentos',
  'orcamentos',
  false,
  52428800                                   -- 50 MB, o mesmo limite da tela
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit;

-- Sem lista de tipos permitidos de propósito: STL, 3MF e STEP não
-- têm um tipo padrão, e cada navegador manda um nome diferente (às
-- vezes manda vazio). Quem filtra a extensão é o servidor, antes de
-- subir. Aqui o que segura é o tamanho — e o fato de que só a chave
-- de serviço escreve.

-- Ler: só o dono, e só dentro da própria pasta. O caminho é
-- <id-do-usuario>/orcamentos/<numero>/<arquivo>.
drop policy if exists "dono le arquivo de orcamento" on storage.objects;
create policy "dono le arquivo de orcamento" on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'orcamentos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "dono apaga arquivo de orcamento" on storage.objects;
create policy "dono apaga arquivo de orcamento" on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'orcamentos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Não existe política de INSERT: quem escreve é o site, pelo
-- servidor, com a chave de serviço. Ninguém logado no app precisa
-- subir arquivo aqui, e o que não é preciso não se abre.

-- ------------------------------------------------------------
--  Conferência
-- ------------------------------------------------------------
-- select id, nome, status, criado_em from public.orcamentos_loja order by criado_em desc;
-- select tipo, count(*) from public.mensagens_loja group by tipo;
-- select id, public, file_size_limit from storage.buckets where id = 'orcamentos';
