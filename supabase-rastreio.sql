-- ============================================================
--  Moldarte 3D · rastreio e acompanhamento do pedido
--
--  Rode DEPOIS de supabase-avisos.sql, no SQL Editor.
--  Pode rodar mais de uma vez sem estragar nada.
--
--  Por que existe: depois de pagar, o cliente não tinha nenhuma
--  forma de saber onde o pedido estava. A única saída era chamar
--  no WhatsApp — e como cada peça leva dias para imprimir, isso
--  virava uma conversa por venda.
-- ============================================================

alter table public.pedidos_loja
  -- Código dos Correios. Fica aqui e não num caderno à parte porque
  -- é o que o cliente vê na página de acompanhar.
  add column if not exists rastreio        text,
  add column if not exists enviado_em      timestamptz,
  -- Marca que o e-mail "seu pedido foi despachado" já saiu. Sem
  -- isso o aviso sairia de novo a cada giro do agendador.
  add column if not exists aviso_envio_em  timestamptz;

-- ------------------------------------------------------------
--  Consulta pública do pedido
--
--  O cliente informa o número e o e-mail. Os dois precisam bater.
--  Só o número não abre nada: se abrisse, bastaria tentar em
--  sequência para ler o endereço de outra pessoa.
--
--  A função é SECURITY DEFINER e devolve só o que interessa a
--  quem comprou — nunca o CPF, nunca o telefone, nunca a chave.
-- ------------------------------------------------------------
create or replace function public.consultar_pedido(
  p_usuario uuid,
  p_id      text,
  p_email   text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido public.pedidos_loja%rowtype;
begin
  select * into v_pedido
    from public.pedidos_loja
   where usuario = p_usuario
     and upper(trim(id)) = upper(trim(p_id))
     -- Comparação frouxa de propósito: quem digita o próprio e-mail
     -- erra maiúscula e espaço o tempo todo.
     and lower(trim(cliente->>'email')) = lower(trim(p_email))
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'erro', 'nao_encontrado');
  end if;

  return jsonb_build_object(
    'ok',        true,
    'id',        v_pedido.id,
    'status',    v_pedido.status,
    'criadoEm',  v_pedido.criado_em,
    'pagoEm',    v_pedido.pago_em,
    'enviadoEm', v_pedido.enviado_em,
    'expiraEm',  v_pedido.expira_em,
    'itens',     v_pedido.itens,
    'subtotal',  v_pedido.subtotal,
    'frete',     v_pedido.frete,
    'total',     v_pedido.total,
    'rastreio',  v_pedido.rastreio,
    -- Só a cidade e o estado. O endereço completo não precisa
    -- trafegar de novo para alguém que já o conhece.
    'cidade',    v_pedido.entrega->>'cidade',
    'uf',        v_pedido.entrega->>'uf',
    -- Link para pagar, quando ainda não foi pago.
    'pagamentoUrl', case when v_pedido.status = 'reservado'
                         then v_pedido.pagamento_url else null end
  );
end;
$$;

-- O site chama esta função pelo servidor, com a chave de serviço.
-- Mesmo assim ela é concedida ao papel anônimo: é uma consulta que
-- exige saber o número E o e-mail, e não devolve dado sensível.
grant execute on function public.consultar_pedido(uuid, text, text) to anon, authenticated;

-- ------------------------------------------------------------
--  Conferência
-- ------------------------------------------------------------
-- select column_name from information_schema.columns
--  where table_name = 'pedidos_loja'
--    and column_name in ('rastreio','enviado_em','aviso_envio_em');
--
-- Troque pelos dados de um pedido real para testar:
-- select public.consultar_pedido(
--   '<seu-id-de-usuario>'::uuid, 'MA3D-XXXX', 'cliente@exemplo.com');
