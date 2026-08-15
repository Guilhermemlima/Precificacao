-- ============================================================
--  Moldarte 3D · e-mails automáticos e avaliações
--
--  Rode DEPOIS de supabase-orcamentos.sql, no SQL Editor.
--  Pode rodar mais de uma vez sem estragar nada.
--
--  Cobre quatro coisas:
--    1. lembrete de pedido não pago  (coluna em pedidos_loja)
--    2. convite para avaliar         (coluna em pedidos_loja)
--    3. avaliações dos produtos      (tabela nova)
--    4. descadastro das novidades    (coluna em mensagens_loja)
-- ============================================================

-- ------------------------------------------------------------
--  1 e 2 · marcas de envio no pedido
--
--  Sem isto, um lembrete que roda de 15 em 15 minutos mandaria o
--  mesmo e-mail para a mesma pessoa a cada rodada. A coluna guarda
--  QUANDO foi enviado, não um sim/não: dá para conferir depois por
--  que alguém recebeu (ou não recebeu) o aviso.
-- ------------------------------------------------------------
alter table public.pedidos_loja
  add column if not exists lembrete_em    timestamptz,
  add column if not exists convite_aval_em timestamptz,
  -- Sorteado na criação do pedido. É o que permite abrir a página de
  -- acompanhamento e a de avaliação sem login: quem tem o link tem
  -- acesso, e o link é impossível de adivinhar. O número do pedido
  -- sozinho não abre nada, senão bastaria tentar sequência.
  add column if not exists chave          text;

-- Preenche quem já existe, para os pedidos antigos também poderem
-- receber convite de avaliação.
update public.pedidos_loja
   set chave = encode(gen_random_bytes(16), 'hex')
 where chave is null;

alter table public.pedidos_loja
  alter column chave set default encode(gen_random_bytes(16), 'hex');

create index if not exists pedidos_loja_chave_idx
  on public.pedidos_loja (chave);

-- ------------------------------------------------------------
--  3 · avaliações
--
--  Só quem comprou avalia, e o vínculo é o pedido: a linha guarda
--  qual pedido deu direito à avaliação. Sem isso a página viraria
--  um mural aberto, e nota de loja que qualquer um escreve não vale
--  nada — nem para quem lê, nem para quem vende.
-- ------------------------------------------------------------
create table if not exists public.avaliacoes (
  id         bigint      generated always as identity primary key,
  usuario    uuid        not null references auth.users(id) on delete cascade,
  slug       text        not null,               -- produto avaliado
  pedido_id  text        not null references public.pedidos_loja(id) on delete cascade,
  nome       text        not null,
  nota       smallint    not null check (nota between 1 and 5),
  comentario text,
  -- Toda avaliação nasce escondida e você libera. Não é para censurar
  -- nota baixa: é para segurar spam e dado pessoal que a pessoa
  -- escreveu sem querer no meio do texto.
  aprovada   boolean     not null default false,
  criado_em  timestamptz not null default now(),
  -- Uma avaliação por produto por pedido. Recarregar a página de
  -- avaliar não cria uma segunda.
  unique (pedido_id, slug)
);

create index if not exists avaliacoes_slug_idx
  on public.avaliacoes (slug, aprovada, criado_em desc);

alter table public.avaliacoes enable row level security;

-- Qualquer visitante lê as aprovadas: é isso que aparece na página do
-- produto. As não aprovadas ficam invisíveis até você liberar.
drop policy if exists "avaliacoes aprovadas sao publicas" on public.avaliacoes;
create policy "avaliacoes aprovadas sao publicas" on public.avaliacoes
  for select
  to anon, authenticated
  using (aprovada = true);

-- O dono vê tudo, inclusive o que ainda não liberou.
drop policy if exists "dono le todas as avaliacoes" on public.avaliacoes;
create policy "dono le todas as avaliacoes" on public.avaliacoes
  for select using (usuario = auth.uid());

drop policy if exists "dono altera avaliacoes" on public.avaliacoes;
create policy "dono altera avaliacoes" on public.avaliacoes
  for update using (usuario = auth.uid()) with check (usuario = auth.uid());

drop policy if exists "dono apaga avaliacoes" on public.avaliacoes;
create policy "dono apaga avaliacoes" on public.avaliacoes
  for delete using (usuario = auth.uid());

-- Não existe política de INSERT: quem grava é o site, pelo servidor,
-- depois de conferir que a chave do pedido bate. Deixar o navegador
-- escrever direto seria abrir o mural que a tabela existe para evitar.

-- ------------------------------------------------------------
--  Nota média por produto
--
--  Uma função em vez de contar no site: a página do produto é
--  gerada no servidor e não pode fazer uma consulta por produto
--  numa listagem de vinte.
-- ------------------------------------------------------------
create or replace function public.notas_dos_produtos(p_usuario uuid)
returns table (slug text, nota numeric, quantas bigint)
language sql
security definer
set search_path = public
as $$
  select a.slug,
         round(avg(a.nota)::numeric, 1) as nota,
         count(*)                       as quantas
    from public.avaliacoes a
   where a.usuario = p_usuario
     and a.aprovada = true
   group by a.slug;
$$;

grant execute on function public.notas_dos_produtos(uuid) to anon, authenticated;

-- ------------------------------------------------------------
--  4 · descadastro das novidades
--
--  Todo e-mail de novidade precisa de um jeito de sair da lista, e
--  o jeito não pode ser "responda pedindo". A chave vai no link do
--  rodapé; quem clica sai sozinho, sem falar com ninguém.
-- ------------------------------------------------------------
alter table public.mensagens_loja
  add column if not exists chave     text,
  add column if not exists saiu_em   timestamptz;

update public.mensagens_loja
   set chave = encode(gen_random_bytes(16), 'hex')
 where chave is null;

alter table public.mensagens_loja
  alter column chave set default encode(gen_random_bytes(16), 'hex');

create index if not exists mensagens_loja_chave_idx
  on public.mensagens_loja (chave);

-- ------------------------------------------------------------
--  Conferência
-- ------------------------------------------------------------
-- select column_name from information_schema.columns
--  where table_name = 'pedidos_loja' and column_name in ('lembrete_em','convite_aval_em','chave');
-- select count(*) from public.avaliacoes;
-- select tipo, count(*) filter (where saiu_em is null) as ativos from public.mensagens_loja group by tipo;
