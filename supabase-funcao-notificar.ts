// ============================================================
//  Edge Function "notificar" · Precifica 3D
//
//  COMO INSTALAR (pelo painel, sem instalar nada no computador):
//    1. Supabase → Edge Functions → Deploy a new function
//    2. Nome: notificar
//    3. Apague o exemplo, cole este arquivo inteiro e publique
//    4. Desligue "Verify JWT" — quem chama é o banco, não um
//       usuário logado. A proteção é o segredo abaixo.
//    5. Em Edge Functions → Secrets, cadastre:
//         VAPID_PUBLICA     → a chave pública (está em vapid-chaves.txt)
//         VAPID_PRIVADA     → a chave privada (está em vapid-chaves.txt)
//         VAPID_ASSUNTO     → mailto:seu-email@exemplo.com
//         NOTIFICAR_SEGREDO → invente uma frase; a mesma vai no SQL
//
//  O que ela faz: recebe {usuario, titulo, corpo}, busca os
//  aparelhos inscritos daquele dono e entrega a mensagem a cada um.
// ============================================================

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const PUBLICA = Deno.env.get("VAPID_PUBLICA") ?? "";
const PRIVADA = Deno.env.get("VAPID_PRIVADA") ?? "";
const ASSUNTO = Deno.env.get("VAPID_ASSUNTO") ?? "mailto:contato@exemplo.com";
const SEGREDO = Deno.env.get("NOTIFICAR_SEGREDO") ?? "";

// A chave de serviço é injetada pelo Supabase. Ela é necessária aqui
// porque a função precisa ler as assinaturas de um dono que não está
// logado nesta chamada — quem disparou foi o banco.
const supabase = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
);

webpush.setVapidDetails(ASSUNTO, PUBLICA, PRIVADA);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("use POST", { status: 405 });
  }

  // Sem JWT, o segredo é a única porta. Comparação simples basta:
  // o valor não vem de usuário final, vem do próprio banco.
  if (!SEGREDO || req.headers.get("x-notificar-segredo") !== SEGREDO) {
    return new Response("segredo inválido", { status: 401 });
  }

  let dados: Record<string, unknown>;
  try {
    dados = await req.json();
  } catch {
    return new Response("corpo inválido", { status: 400 });
  }

  const usuario = String(dados.usuario ?? "");
  const titulo = String(dados.titulo ?? "Precifica 3D");
  const corpo = String(dados.corpo ?? "");
  if (!usuario) return new Response("falta o usuario", { status: 400 });

  const { data: assinaturas, error } = await supabase
    .from("push_assinaturas")
    .select("endpoint, p256dh, auth")
    .eq("usuario", usuario);

  if (error) {
    return new Response(JSON.stringify({ erro: error.message }), { status: 500 });
  }
  if (!assinaturas || assinaturas.length === 0) {
    return Response.json({ enviados: 0, motivo: "nenhum aparelho inscrito" });
  }

  const recado = JSON.stringify({
    titulo,
    corpo,
    url: String(dados.url ?? "/"),
    marca: String(dados.marca ?? "precifica"),
  });

  let enviados = 0;
  const mortos: string[] = [];

  await Promise.all(assinaturas.map(async (a) => {
    try {
      await webpush.sendNotification(
        { endpoint: a.endpoint, keys: { p256dh: a.p256dh, auth: a.auth } },
        recado,
        { TTL: 60 * 60 * 12 },
      );
      enviados++;
    } catch (e) {
      // 404 e 410 significam que aquele navegador desinstalou o app ou
      // limpou os dados. Guardar assinatura morta só faria a próxima
      // notificação demorar mais, então ela sai da tabela.
      const status = (e as { statusCode?: number }).statusCode;
      if (status === 404 || status === 410) mortos.push(a.endpoint);
    }
  }));

  if (mortos.length) {
    await supabase.from("push_assinaturas").delete().in("endpoint", mortos);
  }
  if (enviados) {
    await supabase
      .from("push_assinaturas")
      .update({ usado_em: new Date().toISOString() })
      .eq("usuario", usuario);
  }

  return Response.json({ enviados, removidos: mortos.length });
});
