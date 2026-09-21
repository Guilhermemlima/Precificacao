// ============================================================
//  Edge Function "notificar" · Precifica 3D
//
//  COMO INSTALAR (pelo painel, sem instalar nada no computador):
//    1. Supabase → Edge Functions → Deploy a new function → Via Editor
//    2. Nome: notificar
//    3. Apague o exemplo, cole este arquivo INTEIRO e publique.
//       Não edite nada aqui dentro: os valores ficam nos Secrets.
//    4. Desligue "Verify JWT" — quem chama é o banco, não um
//       usuário logado. A proteção é o segredo abaixo.
//    5. Em Secrets, cadastre (os valores estão em vapid-chaves.txt):
//         VAPID_PUBLICA · VAPID_PRIVADA · VAPID_ASSUNTO · NOTIFICAR_SEGREDO
//       SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY o Supabase injeta sozinho.
//
//  Por que sem biblioteca: as bibliotecas de web push são feitas para
//  Node e nem sempre carregam no runtime do Supabase — a primeira versão
//  deste arquivo usava uma delas e a função nem subia (WORKER_ERROR).
//  Aqui tudo é feito com WebCrypto, que já vem no ambiente.
// ============================================================

const PUBLICA = Deno.env.get("VAPID_PUBLICA") ?? "";
const PRIVADA = Deno.env.get("VAPID_PRIVADA") ?? "";
const ASSUNTO = Deno.env.get("VAPID_ASSUNTO") ?? "mailto:contato@exemplo.com";
const SEGREDO = Deno.env.get("NOTIFICAR_SEGREDO") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPA_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

/* ---------- utilidades de base64url ---------- */
function paraBytes(b64: string): Uint8Array {
  const texto = atob(b64.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - b64.length % 4) % 4));
  const saida = new Uint8Array(texto.length);
  for (let i = 0; i < texto.length; i++) saida[i] = texto.charCodeAt(i);
  return saida;
}
function paraB64(bytes: ArrayBuffer | Uint8Array): string {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function junta(...partes: Uint8Array[]): Uint8Array {
  const total = partes.reduce((n, p) => n + p.length, 0);
  const saida = new Uint8Array(total);
  let i = 0;
  for (const p of partes) { saida.set(p, i); i += p.length; }
  return saida;
}

/* ---------- VAPID: prova de que o envio é seu (RFC 8292) ----------
   O servidor de push do navegador só aceita a mensagem se ela vier
   assinada pela mesma chave que o navegador guardou na inscrição. */
async function cabecalhoVapid(endpoint: string): Promise<string> {
  const origem = new URL(endpoint).origin;
  const cabecalho = paraB64(new TextEncoder().encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const corpo = paraB64(new TextEncoder().encode(JSON.stringify({
    aud: origem,
    exp: Math.floor(Date.now() / 1000) + 12 * 60 * 60,
    sub: ASSUNTO,
  })));

  // A chave privada guarda só o "d"; o x e o y saem da pública, que é o
  // ponto não comprimido: 0x04 seguido de 32 bytes de cada coordenada.
  const pub = paraBytes(PUBLICA);
  const chave = await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC", crv: "P-256", ext: true,
      d: PRIVADA,
      x: paraB64(pub.slice(1, 33)),
      y: paraB64(pub.slice(33, 65)),
    },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const assinatura = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    chave,
    new TextEncoder().encode(cabecalho + "." + corpo),
  );

  return `vapid t=${cabecalho}.${corpo}.${paraB64(assinatura)}, k=${PUBLICA}`;
}

/* ---------- criptografia da mensagem (RFC 8291, aes128gcm) ----------
   O conteúdo é cifrado para aquele navegador específico: nem o serviço
   de push da Google consegue ler o texto do aviso. */
async function derivar(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, tamanho: number) {
  const base = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt, info },
    base,
    tamanho * 8,
  );
  return new Uint8Array(bits);
}

async function cifrar(p256dh: string, auth: string, texto: string): Promise<Uint8Array> {
  const uaPublica = paraBytes(p256dh);
  const authSecret = paraBytes(auth);

  // Par efêmero: uma chave nova por mensagem.
  const efemero = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPublica = new Uint8Array(await crypto.subtle.exportKey("raw", efemero.publicKey));

  const daOutraParte = await crypto.subtle.importKey(
    "raw", uaPublica, { name: "ECDH", namedCurve: "P-256" }, false, [],
  );
  const compartilhado = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: daOutraParte }, efemero.privateKey, 256),
  );

  const enc = new TextEncoder();
  const infoChave = junta(enc.encode("WebPush: info\0"), uaPublica, asPublica);
  const ikm = await derivar(authSecret, compartilhado, infoChave, 32);

  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await derivar(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await derivar(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);

  const chaveAes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  // O 0x02 marca que este é o último (e único) bloco da mensagem.
  const claro = junta(enc.encode(texto), new Uint8Array([2]));
  const cifrado = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, chaveAes, claro),
  );

  // Cabeçalho do corpo: salt | tamanho do registro | tamanho da chave | chave
  const tamanhoRegistro = new Uint8Array([0, 0, 0x10, 0]); // 4096
  return junta(salt, tamanhoRegistro, new Uint8Array([asPublica.length]), asPublica, cifrado);
}

/* ---------- banco, pela API REST (sem biblioteca) ---------- */
function banco(caminho: string, opcoes: RequestInit = {}) {
  return fetch(SUPA_URL + "/rest/v1/" + caminho, {
    ...opcoes,
    headers: {
      apikey: SUPA_KEY,
      Authorization: "Bearer " + SUPA_KEY,
      "Content-Type": "application/json",
      ...(opcoes.headers ?? {}),
    },
  });
}

/* ---------- a função ---------- */
Deno.serve(async (req: Request) => {
  // Abrir o endereço no navegador cai aqui e vira uma conferência: diz
  // quais segredos chegaram, sem nunca mostrar o valor de nenhum deles.
  // SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY não se cadastram — o
  // Supabase injeta sozinho, e o painel recusa esse prefixo.
  if (req.method === "GET") {
    const faltando = [
      ["VAPID_PUBLICA", PUBLICA],
      ["VAPID_PRIVADA", PRIVADA],
      ["NOTIFICAR_SEGREDO", SEGREDO],
      ["SUPABASE_URL (automático)", SUPA_URL],
      ["SUPABASE_SERVICE_ROLE_KEY (automático)", SUPA_KEY],
    ].filter(([, v]) => !v).map(([n]) => n);

    return Response.json({
      funcao: "notificar",
      pronta: faltando.length === 0,
      faltando,
      assunto: ASSUNTO,
      instrucao: faltando.length === 0
        ? "Tudo no lugar. Agora rode o teste pelo SQL Editor."
        : "Cadastre os itens acima em Edge Functions → Secrets.",
    });
  }

  if (req.method !== "POST") return new Response("use POST", { status: 405 });

  if (!SEGREDO || req.headers.get("x-notificar-segredo") !== SEGREDO) {
    return new Response("segredo inválido", { status: 401 });
  }
  if (!PUBLICA || !PRIVADA) {
    return new Response("faltam VAPID_PUBLICA e VAPID_PRIVADA nos Secrets", { status: 500 });
  }

  let dados: Record<string, unknown>;
  try { dados = await req.json(); } catch { return new Response("corpo inválido", { status: 400 }); }

  const usuario = String(dados.usuario ?? "");
  if (!usuario) return new Response("falta o usuario", { status: 400 });

  const resposta = await banco(
    "push_assinaturas?select=endpoint,p256dh,auth&usuario=eq." + encodeURIComponent(usuario),
  );
  if (!resposta.ok) {
    return new Response(JSON.stringify({ erro: await resposta.text() }), { status: 500 });
  }
  const assinaturas: Array<{ endpoint: string; p256dh: string; auth: string }> = await resposta.json();
  if (assinaturas.length === 0) {
    return Response.json({ enviados: 0, motivo: "nenhum aparelho inscrito" });
  }

  const recado = JSON.stringify({
    titulo: String(dados.titulo ?? "Precifica 3D"),
    corpo: String(dados.corpo ?? ""),
    url: String(dados.url ?? "/"),
    marca: String(dados.marca ?? "precifica"),
  });

  let enviados = 0;
  const mortos: string[] = [];
  const falhas: string[] = [];

  await Promise.all(assinaturas.map(async (a) => {
    try {
      const corpo = await cifrar(a.p256dh, a.auth, recado);
      const r = await fetch(a.endpoint, {
        method: "POST",
        headers: {
          Authorization: await cabecalhoVapid(a.endpoint),
          "Content-Encoding": "aes128gcm",
          "Content-Type": "application/octet-stream",
          TTL: "43200",
        },
        body: corpo,
      });
      if (r.ok) enviados++;
      // 404 e 410: o navegador desinstalou o app ou limpou os dados.
      // Guardar destino morto só atrasaria os próximos envios.
      else if (r.status === 404 || r.status === 410) mortos.push(a.endpoint);
      else falhas.push(r.status + ": " + (await r.text()).slice(0, 120));
    } catch (e) {
      falhas.push(String((e as Error).message ?? e).slice(0, 120));
    }
  }));

  for (const endpoint of mortos) {
    await banco("push_assinaturas?endpoint=eq." + encodeURIComponent(endpoint), { method: "DELETE" });
  }
  if (enviados) {
    await banco("push_assinaturas?usuario=eq." + encodeURIComponent(usuario), {
      method: "PATCH",
      body: JSON.stringify({ usado_em: new Date().toISOString() }),
    });
  }

  return Response.json({ enviados, removidos: mortos.length, falhas });
});
