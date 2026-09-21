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
--  O endereço e o segredo ficam SÓ aqui. Os gatilhos abaixo chamam
--  esta função, então mudar de projeto ou trocar o segredo é mexer
--  em um lugar, não em três.
create or replace function public.envia_aviso(
  p_usuario uuid,
  p_titulo  text,
  p_corpo   text,
  p_url     text default '/',
  p_marca   text default 'precifica'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  destino text := 'https://SEU-PROJETO.supabase.co/functions/v1/notificar';  -- <<< TROQUE pelo seu projeto
  segredo text := 'COLE-AQUI-O-MESMO-SEGREDO-DA-FUNCAO';                     -- <<< TROQUE (o mesmo de NOTIFICAR_SEGREDO)
begin
  perform net.http_post(
    url     := destino,
    headers := jsonb_build_object(
                 'Content-Type',        'application/json',
                 'x-notificar-segredo', segredo
               ),
    body    := jsonb_build_object(
                 'usuario', p_usuario,
                 'titulo',  p_titulo,
                 'corpo',   p_corpo,
                 'url',     p_url,
                 'marca',   p_marca
               )
  );
end $$;

create or replace function public.avisa_celular()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  titulo  text;
  corpo   text;
  nome    text;
  valor   text;
begin
  nome := coalesce(nullif(new.cliente->>'nome', ''), 'Cliente');

  -- translate troca ponto por vírgula e vice-versa de uma vez. Sem isso o
  -- valor sairia no formato do servidor (249.90), e não no nosso (249,90):
  -- as letras G e D do to_char seguem a configuração regional do banco.
  valor := 'R$ ' || translate(to_char(new.total, 'FM999,999,990.00'), ',.', '.,');

  if tg_op = 'INSERT' then
    titulo := 'Pedido novo na loja';
    corpo  := nome || ' · ' || valor || ' · aguardando pagamento';

  elsif new.status = 'pago' and coalesce(old.status, '') <> 'pago' then
    titulo := 'Pagamento confirmado';
    corpo  := nome || ' pagou ' || valor || ' · pode produzir';

  else
    return new;   -- qualquer outra alteração não vira aviso
  end if;

  perform public.envia_aviso(new.usuario, titulo, corpo, '/?aba=gestao', 'pedido-' || new.id);
  return new;
end $$;

drop trigger if exists pedidos_loja_avisa on public.pedidos_loja;
create trigger pedidos_loja_avisa
  after insert or update of status on public.pedidos_loja
  for each row execute function public.avisa_celular();

-- ------------------------------------------------------------
--  2b · Pedido personalizado (orçamento)
--
--  Quem pede peça sob encomenda não passa pelo carrinho: preenche o
--  formulário de orçamento. Sem este gatilho, só se descobria o
--  pedido abrindo o sistema — que é justamente o que queremos evitar.
-- ------------------------------------------------------------
create or replace function public.avisa_orcamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  resumo text;
begin
  -- O começo da descrição já diz do que se trata; o resto fica no sistema.
  resumo := coalesce(nullif(trim(new.descricao), ''), 'sem descrição');
  if length(resumo) > 90 then
    resumo := left(resumo, 87) || '...';
  end if;

  perform public.envia_aviso(
    new.usuario,
    'Pedido personalizado',
    new.nome || ' · ' || new.quantidade || ' un · ' || resumo,
    '/?aba=gestao',
    'orcamento-' || new.id
  );
  return new;
end $$;

drop trigger if exists orcamentos_loja_avisa on public.orcamentos_loja;
create trigger orcamentos_loja_avisa
  after insert on public.orcamentos_loja
  for each row execute function public.avisa_orcamento();

-- ------------------------------------------------------------
--  2c · Mensagem de contato
--
--  Só as mensagens de verdade. Cadastro de novidades entra na mesma
--  tabela com tipo 'novidades', e avisar a cada inscrição de
--  newsletter transformaria a notificação em barulho — quando tudo
--  apita, nada apita.
-- ------------------------------------------------------------
create or replace function public.avisa_mensagem()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  resumo text;
begin
  if new.tipo <> 'contato' then
    return new;
  end if;

  resumo := coalesce(nullif(trim(new.assunto), ''), nullif(trim(new.mensagem), ''), 'sem assunto');
  if length(resumo) > 90 then
    resumo := left(resumo, 87) || '...';
  end if;

  perform public.envia_aviso(
    new.usuario,
    'Mensagem no site',
    coalesce(nullif(new.nome, ''), 'Alguém') || ' · ' || resumo,
    '/?aba=gestao',
    'mensagem-' || new.id
  );
  return new;
end $$;

drop trigger if exists mensagens_loja_avisa on public.mensagens_loja;
create trigger mensagens_loja_avisa
  after insert on public.mensagens_loja
  for each row execute function public.avisa_mensagem();

-- ------------------------------------------------------------
--  3 · Teste manual
--
--  Para conferir sem precisar de um pedido de verdade, troque o
--  endereço e o segredo abaixo e rode só este trecho. Deve chegar
--  uma notificação no celular em alguns segundos.
--
--  O dono sai da própria tabela de assinaturas. No SQL Editor você
--  roda como postgres, não como usuário logado, então auth.uid()
--  viria nulo e a função recusaria a chamada.
-- ------------------------------------------------------------
--  Usa a mesma função dos gatilhos, então testa o endereço e o segredo
--  de verdade — e não uma cópia deles escrita aqui, que poderia estar
--  certa enquanto a de lá está errada.
-- select public.envia_aviso(
--   (select usuario from public.push_assinaturas order by criado_em desc limit 1),
--   'Teste do Precifica',
--   'Se você está lendo isto, as notificações funcionam.'
-- );
--
-- Uns 5 segundos depois, veja o que a função respondeu:
--   select status_code, content from net._http_response
--    order by created desc limit 3;
-- Esperado: 200 e algo como {"enviados":1,"removidos":0}

-- ------------------------------------------------------------
--  4 · Conferência
-- ------------------------------------------------------------
-- Aparelhos inscritos:
--   select aparelho, criado_em, usado_em from public.push_assinaturas;
--
-- Respostas das últimas chamadas (o corpo vem em pg_net):
--   select status_code, content from net._http_response
--    order by created desc limit 5;
