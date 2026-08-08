-- ============================================================
--  Precifica 3D — estrutura do banco no Supabase
--  Rode este arquivo UMA VEZ no SQL Editor do seu projeto.
--  (Supabase → SQL Editor → New query → cole tudo → Run)
-- ============================================================

-- ------------------------------------------------------------
--  Tabela única de dados
--
--  Por que uma tabela só, com jsonb, em vez de uma tabela por
--  assunto: o app é local-first e sincroniza documentos inteiros.
--  Uma tabela genérica deixa a sincronização simples e evita
--  migração de schema toda vez que um campo novo aparece no app.
--  Continua sendo Postgres: dá para consultar por dentro do jsonb,
--  e as views no fim deste arquivo expõem tudo em colunas normais.
-- ------------------------------------------------------------
create table if not exists public.dados (
  usuario       uuid        not null default auth.uid() references auth.users(id) on delete cascade,
  colecao       text        not null,
  id            text        not null,
  conteudo      jsonb       not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  apagado       boolean     not null default false,
  primary key (usuario, colecao, id)
);

-- Busca por "o que mudou desde a última sincronização"
create index if not exists dados_sync_idx
  on public.dados (usuario, atualizado_em desc);

comment on table public.dados is 'Documentos do Precifica 3D. colecao: config, pedido, rolo, catalogo, peca.';

-- ------------------------------------------------------------
--  Segurança: cada pessoa só enxerga e escreve o que é dela.
--  É isto que torna seguro deixar a chave anon no navegador.
-- ------------------------------------------------------------
alter table public.dados enable row level security;

drop policy if exists "dono le" on public.dados;
create policy "dono le" on public.dados
  for select using (usuario = auth.uid());

drop policy if exists "dono escreve" on public.dados;
create policy "dono escreve" on public.dados
  for insert with check (usuario = auth.uid());

drop policy if exists "dono altera" on public.dados;
create policy "dono altera" on public.dados
  for update using (usuario = auth.uid()) with check (usuario = auth.uid());

drop policy if exists "dono apaga" on public.dados;
create policy "dono apaga" on public.dados
  for delete using (usuario = auth.uid());

-- Carimba a data em toda escrita, para a sincronização não depender
-- do relógio do celular, que pode estar errado.
create or replace function public.carimba_atualizacao()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  new.usuario := coalesce(new.usuario, auth.uid());
  return new;
end $$;

drop trigger if exists dados_carimbo on public.dados;
create trigger dados_carimbo
  before insert or update on public.dados
  for each row execute function public.carimba_atualizacao();

-- As imagens do catálogo entram como linhas de colecao='imagem', já
-- reduzidas pelo app (logo em PNG até 700 px, fotos em JPEG até 1100 px).
-- Ficam na casa das centenas de KB cada, e assim a sincronização é uma
-- só, sem um segundo caminho para arquivos.

-- ------------------------------------------------------------
--  Views: os mesmos dados em colunas, para consultar no SQL Editor
--  ou ligar num BI depois. security_invoker faz a view respeitar
--  as regras acima, em vez de furá-las.
-- ------------------------------------------------------------
create or replace view public.meus_pedidos
with (security_invoker = true) as
select
  id,
  conteudo->>'cliente'              as cliente,
  conteudo->>'peca'                 as peca,
  conteudo->>'status'               as status,
  nullif(conteudo->>'data','')::date     as data,
  nullif(conteudo->>'entrega','')::date  as entrega,
  (conteudo->>'qtd')::numeric       as quantidade,
  (conteudo->>'receita')::numeric   as receita,
  (conteudo->>'taxas')::numeric     as taxas,
  (conteudo->>'custoProducao')::numeric  as custo_producao,
  (conteudo->>'custoTrabalho')::numeric  as custo_trabalho,
  (conteudo->>'custoEstrutura')::numeric as custo_estrutura,
  (conteudo->>'receita')::numeric
    - (conteudo->>'taxas')::numeric
    - (conteudo->>'custoProducao')::numeric
    - (conteudo->>'custoTrabalho')::numeric
    - (conteudo->>'custoEstrutura')::numeric as lucro,
  (conteudo->>'horas')::numeric     as horas_maquina,
  (conteudo->>'gramas')::numeric    as gramas,
  atualizado_em
from public.dados
where colecao = 'pedido' and not apagado;

create or replace view public.meu_estoque
with (security_invoker = true) as
select
  id,
  conteudo->>'nome'  as cor,
  conteudo->>'hex'   as hex,
  conteudo->>'tipo'  as tipo,
  conteudo->>'marca' as marca,
  replace(conteudo->>'g','.','')::numeric        as gramas,
  replace(replace(conteudo->>'preco','.',''),',','.')::numeric as preco_kg,
  atualizado_em
from public.dados
where colecao = 'rolo' and not apagado;

-- Receita por mês, já pronta
create or replace view public.receita_mensal
with (security_invoker = true) as
select
  to_char(data, 'YYYY-MM')   as mes,
  count(*)                   as pedidos,
  sum(receita)               as receita,
  sum(lucro)                 as lucro
from public.meus_pedidos
where status in ('pago','entregue')
group by 1
order by 1 desc;
