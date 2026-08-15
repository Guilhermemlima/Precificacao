-- ============================================================
--  Moldarte 3D · agendador dos e-mails automáticos
--
--  Rode DEPOIS de supabase-avisos.sql.
--
--  ANTES DE RODAR, troque as duas linhas marcadas com <<< TROQUE:
--  o endereço do site e o segredo do cron. O segredo é o mesmo
--  valor que você cadastrou como CRON_SECRET na Vercel — se não
--  bater, o site recusa a chamada e nenhum e-mail sai.
--
--  Este arquivo faz o Supabase chamar o site de 15 em 15 minutos.
--  O trabalho todo acontece lá; aqui só existe o despertador.
-- ============================================================

-- pg_cron agenda; pg_net faz a chamada HTTP sem travar o banco
-- esperando a resposta.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ------------------------------------------------------------
--  O despertador
--
--  De 15 em 15 minutos. Não precisa ser mais frequente: o lembrete
--  só vale para pedido com mais de uma hora, então quinze minutos
--  de imprecisão não mudam nada — e cada giro é uma chamada a
--  menos gasta à toa.
-- ------------------------------------------------------------
select cron.unschedule('moldarte-avisos')
 where exists (select 1 from cron.job where jobname = 'moldarte-avisos');

select cron.schedule(
  'moldarte-avisos',
  '*/15 * * * *',
  $$
  select net.http_post(
    url     := 'https://www.3dmoldarte.com.br/api/cron',   -- <<< TROQUE se o endereço mudar
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'x-cron-secret', 'COLE-AQUI-O-MESMO-CRON_SECRET-DA-VERCEL'  -- <<< TROQUE
               ),
    body    := '{}'::jsonb
  );
  $$
);

-- ------------------------------------------------------------
--  Reservas vencidas
--
--  Já existia a função expirar_reservas(), mas nada a chamava:
--  ela só rodava de carona quando alguém abria a loja. Pedido
--  abandonado de madrugada segurava o estoque até o primeiro
--  visitante do dia seguinte.
-- ------------------------------------------------------------
select cron.unschedule('moldarte-expirar')
 where exists (select 1 from cron.job where jobname = 'moldarte-expirar');

select cron.schedule(
  'moldarte-expirar',
  '*/15 * * * *',
  $$
  -- A função recebe o dono, então roda uma vez por dono que tenha
  -- reserva aberta. Hoje é só você; escrito assim continua certo se
  -- um dia houver outra conta.
  select public.expirar_reservas(usuario)
    from (select distinct usuario
            from public.pedidos_loja
           where status = 'reservado') donos;
  $$
);

-- ------------------------------------------------------------
--  Conferência
-- ------------------------------------------------------------
-- Os dois agendamentos devem aparecer, com active = true:
--   select jobname, schedule, active from cron.job order by jobname;
--
-- As últimas execuções, para ver se deu certo:
--   select j.jobname, r.status, r.return_message, r.start_time
--     from cron.job_run_details r
--     join cron.job j on j.jobid = r.jobid
--    order by r.start_time desc limit 10;
--
-- A resposta que o site devolveu (o corpo vem em pg_net):
--   select status_code, content from net._http_response order by created desc limit 5;
