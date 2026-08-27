-- ============================================================
--  Moldarte 3D · auditoria do banco
--
--  Não altera nada: só relata o que existe e o que falta.
--  Cole inteiro no SQL Editor e rode. Cada linha diz OK ou FALTA,
--  e qual arquivo resolve.
-- ============================================================

with checagens as (
  select * from (values
    -- tabelas
    ('tabela dados',            'supabase-schema.sql',     to_regclass('public.dados')            is not null),
    ('tabela pedidos_loja',     'supabase-estoque.sql',    to_regclass('public.pedidos_loja')     is not null),
    ('tabela estoque_movimento','supabase-estoque.sql',    to_regclass('public.estoque_movimento')is not null),
    ('tabela cupons',           'supabase-cupons.sql',     to_regclass('public.cupons')           is not null),
    ('tabela orcamentos_loja',  'supabase-orcamentos.sql', to_regclass('public.orcamentos_loja')  is not null),
    ('tabela mensagens_loja',   'supabase-orcamentos.sql', to_regclass('public.mensagens_loja')   is not null),
    ('tabela avaliacoes',       'supabase-avisos.sql',     to_regclass('public.avaliacoes')       is not null),

    -- funções
    ('func criar_pedido',       'supabase-estoque.sql',    to_regproc('public.criar_pedido')      is not null),
    ('func cancelar_pedido',    'supabase-estoque.sql',    to_regproc('public.cancelar_pedido')   is not null),
    ('func expirar_reservas',   'supabase-estoque.sql',    to_regproc('public.expirar_reservas')  is not null),
    ('func estoque_disponivel', 'supabase-estoque.sql',    to_regproc('public.estoque_disponivel')is not null),
    ('func valida_cupom',       'supabase-cupons.sql',     to_regproc('public.valida_cupom')      is not null),
    ('func consultar_pedido',   'supabase-rastreio.sql',   to_regproc('public.consultar_pedido')  is not null),
    ('func notas_dos_produtos', 'supabase-avisos.sql',     to_regproc('public.notas_dos_produtos')is not null),

    -- colunas que vieram depois
    ('col pagamento_url',   'supabase-pagamento.sql',  exists(select 1 from information_schema.columns where table_name='pedidos_loja' and column_name='pagamento_url')),
    ('col cupom/desconto',  'supabase-cupons.sql',     exists(select 1 from information_schema.columns where table_name='pedidos_loja' and column_name='desconto')),
    ('col lembrete_em',     'supabase-avisos.sql',     exists(select 1 from information_schema.columns where table_name='pedidos_loja' and column_name='lembrete_em')),
    ('col chave do pedido', 'supabase-avisos.sql',     exists(select 1 from information_schema.columns where table_name='pedidos_loja' and column_name='chave')),
    ('col rastreio',        'supabase-rastreio.sql',   exists(select 1 from information_schema.columns where table_name='pedidos_loja' and column_name='rastreio')),
    ('col saiu_em',         'supabase-avisos.sql',     exists(select 1 from information_schema.columns where table_name='mensagens_loja' and column_name='saiu_em')),

    -- baldes de arquivo
    ('balde loja publico',       'supabase-loja.sql',       exists(select 1 from storage.buckets where id='loja' and public)),
    ('balde orcamentos privado', 'supabase-orcamentos.sql', exists(select 1 from storage.buckets where id='orcamentos' and not public)),

    -- leitura pública da vitrine
    ('vitrine publica', 'supabase-loja.sql',
      exists(select 1 from pg_policies where tablename='dados' and cmd='SELECT' and qual like '%loja%')),

    -- correções que reescrevem função existente
    ('correcao do preco (faixa de 1 un)', 'supabase-preco.sql',
      exists(select 1 from pg_proc where proname='criar_pedido' and prosrc like '%> 1%')),

    -- o desconto do Pix (supabase-pix.sql)
    ('col desconto_pix', 'supabase-pix.sql',
      exists(select 1 from information_schema.columns
              where table_name='pedidos_loja' and column_name='desconto_pix')),
    ('criar_pedido conhece o Pix', 'supabase-pix.sql',
      exists(select 1 from pg_proc
              where proname='criar_pedido'
                and pg_get_function_identity_arguments(oid) like '%p_desconto_pix%')),

    -- clientes e cupom com dono (supabase-clientes.sql)
    ('func clientes_loja', 'supabase-clientes.sql',
      to_regproc('public.clientes_loja') is not null),
    ('col email no cupom', 'supabase-clientes.sql',
      exists(select 1 from information_schema.columns
              where table_name='cupons' and column_name='email')),
    ('valida_cupom confere o dono', 'supabase-clientes.sql',
      exists(select 1 from pg_proc
              where proname='valida_cupom'
                and pg_get_function_identity_arguments(oid) like '%p_email%')),
    -- Duas versoes vivas da mesma funcao deixam a chamada ambigua, e o
    -- banco recusa as duas. So pode existir uma.
    ('valida_cupom sem versao duplicada', 'supabase-clientes.sql',
      (select count(*) from pg_proc where proname='valida_cupom') = 1),
    ('criar_pedido sem versao duplicada', 'supabase-pix.sql',
      (select count(*) from pg_proc where proname='criar_pedido') = 1),

    -- pedidos de empresa (supabase-brindes.sql)
    ('col empresa no orcamento', 'supabase-brindes.sql',
      exists(select 1 from information_schema.columns
              where table_name='orcamentos_loja' and column_name='empresa')),
    ('col documento no orcamento', 'supabase-brindes.sql',
      exists(select 1 from information_schema.columns
              where table_name='orcamentos_loja' and column_name='documento')),
    ('col origem no orcamento', 'supabase-brindes.sql',
      exists(select 1 from information_schema.columns
              where table_name='orcamentos_loja' and column_name='origem')),

    -- agendador
    ('extensao pg_cron',  'supabase-cron.sql', exists(select 1 from pg_extension where extname='pg_cron')),
    ('extensao pg_net',   'supabase-cron.sql', exists(select 1 from pg_extension where extname='pg_net')),
    ('job moldarte-avisos',  'supabase-cron.sql', exists(select 1 from cron.job where jobname='moldarte-avisos'  and active)),
    ('job moldarte-expirar', 'supabase-cron.sql', exists(select 1 from cron.job where jobname='moldarte-expirar' and active))
  ) as t(item, arquivo, ok)
)
select case when ok then 'OK' else 'FALTA' end as situacao,
       item,
       case when ok then '' else arquivo end as rodar
  from checagens
 order by ok, item;
