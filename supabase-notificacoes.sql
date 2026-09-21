-- ============================================================
--  Precifica 3D · notificações no celular
--
--  Rode no SQL Editor DEPOIS de supabase-estoque.sql (que cria
--  pedidos_loja). Pode rodar mais de uma vez sem estragar nada.
--
--  ANTES DE RODAR, troque as duas linhas marcadas com <<< TROQUE.
--
--  O que este arquivo faz:
--    1. guarda quais aparelhos pedem para ser avisados
--    2. dispara um aviso quando entra pedido novo na loja
--    3. dispara outro quando um pedido é pago
--
--  Quem realmente envia é a Edge Function "notificar". Aqui só
--  existe o gatilho: o banco avisa a função, e a função avisa o
--  celular. Assim o aviso sai no instante do pedido, sem depender
--  de ninguém abrir o site.
-- ============================================================

create extension if not exists pg_net;

-- ------------------------------------------------------------
--  1 · Aparelhos inscritos
--
--  Cada navegador que aceita receber aviso gera um endereço único
--  (o endpoint). Celular e computador são inscrições diferentes, e
--  é por isso que a chave é o endpoint, não o usuário: quem tem
--  dois aparelhos recebe nos dois.
-- ------------------------------------------------------------
create table if not exists public.push_assinaturas (
  endpoint   text        primary key,
  usuario    uuid        not null references auth.users(id) on delete cascade,
  p256dh     text        not null,   -- chave pública do navegador
  auth       text        not null,   -- segredo do navegador
  aparelho   text,                   -- só para você reconhecer na lista
  criado_em  timestamptz not null default now(),
  usado_em   timestamptz
);

create index if not exists push_assinaturas_usuario_idx
  on public.push_assinaturas (usuario);

alter table public.push_assinaturas enable row level security;

-- Cada pessoa cuida apenas das próprias inscrições.
drop policy if exists "dono le assinaturas" on public.push_assinaturas;
create policy "dono le assinaturas" on public.push_assinaturas
  for select using (usuario = auth.uid());

drop policy if exists "dono cria assinaturas" on public.push_assinaturas;
create policy "dono cria assinaturas" on public.push_assinaturas
  for insert with check (usuario = auth.uid());

drop policy if exists "dono altera assinaturas" on public.push_assinaturas;
create policy "dono altera assinaturas" on public.push_assinaturas
  for update using (usuario = auth.uid()) with check (usuario = auth.uid());

drop policy if exists "dono apaga assinaturas" on public.push_assinaturas;
create policy "dono apaga assinaturas" on public.push_assinaturas
  for delete using (usuario = auth.uid());

-- ------------------------------------------------------------
--  2 · O gatilho
--
--  pg_net envia a chamada e não espera resposta, então uma falha
--  na notificação nunca trava nem desfaz a gravação do pedido.
--  Pedido tem que entrar mesmo que o aviso falhe.
-- ------------------------------------------------------------
create or replace function public.avisa_celular()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  destino text := 'https://SEU-PROJETO.supabase.co/functions/v1/notificar';  -- <<< TROQUE pelo seu projeto
  segredo text := 'COLE-AQUI-O-MESMO-SEGREDO-DA-FUNCAO';                     -- <<< TROQUE (o mesmo de NOTIFICAR_SEGREDO)
  titulo  text;
  corpo   text;
  nome    text;
begin
  nome := coalesce(nullif(new.cliente->>'nome', ''), 'Cliente');

  if tg_op = 'INSERT' then
    titulo := 'Pedido novo na loja';
    corpo  := nome || ' · ' || to_char(new.total, 'FM999G999D00') || ' · aguardando pagamento';

  elsif new.status = 'pago' and coalesce(old.status, '') <> 'pago' then
    titulo := 'Pagamento confirmado';
    corpo  := nome || ' pagou ' || to_char(new.total, 'FM999G999D00') || ' · pode produzir';

  else
    return new;   -- qualquer outra alteração não vira aviso
  end if;

  perform net.http_post(
    url     := destino,
    headers := jsonb_build_object(
                 'Content-Type',       'application/json',
                 'x-notificar-segredo', segredo
               ),
    body    := jsonb_build_object(
                 'usuario', new.usuario,
                 'titulo',  titulo,
                 'corpo',   corpo,
                 'url',     '/?aba=gestao',
                 'marca',   'pedido-' || new.id
               )
  );

  return new;
end $$;

drop trigger if exists pedidos_loja_avisa on public.pedidos_loja;
create trigger pedidos_loja_avisa
  after insert or update of status on public.pedidos_loja
  for each row execute function public.avisa_celular();

-- ------------------------------------------------------------
--  3 · Teste manual
--
--  Para conferir sem precisar de um pedido de verdade, troque o
--  endereço e o segredo abaixo e rode só este trecho. Deve chegar
--  uma notificação no celular em alguns segundos.
-- ------------------------------------------------------------
-- select net.http_post(
--   url     := 'https://SEU-PROJETO.supabase.co/functions/v1/notificar',
--   headers := jsonb_build_object('Content-Type','application/json',
--                                 'x-notificar-segredo','O-SEGREDO'),
--   body    := jsonb_build_object(
--                'usuario', auth.uid(),
--                'titulo',  'Teste do Precifica',
--                'corpo',   'Se você está lendo isto, as notificações funcionam.')
-- );

-- ------------------------------------------------------------
--  4 · Conferência
-- ------------------------------------------------------------
-- Aparelhos inscritos:
--   select aparelho, criado_em, usado_em from public.push_assinaturas;
--
-- Respostas das últimas chamadas (o corpo vem em pg_net):
--   select status_code, content from net._http_response
--    order by created desc limit 5;
