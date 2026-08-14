# Precifica 3D

Calculadora de precificação para impressão 3D sob encomenda. Página única em HTML, sem dependências e sem build: baixe `index.html` e abra no navegador, ou publique a pasta em qualquer hospedagem estática (Vercel, Netlify, GitHub Pages) sem nenhuma configuração.

## Sincronização na nuvem (opcional)

O app funciona sozinho, sem conta. Ligando a nuvem, os dados passam a existir também num Postgres no Supabase, e celular e computador enxergam os mesmos pedidos.

**Desenho local-first:** o navegador continua sendo o armazenamento de trabalho — o app abre e funciona sem internet, e a sincronização acontece por trás. Nada depende de estar online.

### Como ligar

1. Crie um projeto gratuito no Supabase.
2. No **SQL Editor**, rode o arquivo [`supabase-schema.sql`](supabase-schema.sql). Ele cria a tabela, as regras de acesso por usuário e as views de consulta.
3. No app, botão **Nuvem** → cole a **URL do projeto** e a **chave anon** (Project Settings → API), crie a conta e entre.
4. No primeiro aparelho, use **Enviar tudo deste aparelho** para subir o que já existe.

A chave anon é feita para ficar no navegador; quem protege os dados é o Row Level Security, que amarra cada linha ao `auth.uid()` do dono. Ela fica salva só no seu aparelho — não vai para o repositório.

### Como a sincronização funciona

- **Sem biblioteca**: fala direto com a API REST do Supabase por `fetch`, mantendo o arquivo único e o funcionamento offline.
- **Granularidade**: pedidos, rolos de filamento e imagens sincronizam registro a registro; catálogo, configurações e peças salvas vão como documento inteiro, por mudarem pouco e quase sempre num aparelho só.
- **Conflito**: vence a alteração mais recente.
- **Exclusões** viram lápides, removidas só quando o servidor confirma.
- **Relógio**: depois de gravar, o app adota a hora do servidor como carimbo. Sem isso, um aparelho adiantado reenviaria os mesmos registros para sempre.
- **Eco**: o que acaba de chegar do servidor não volta a subir no mesmo ciclo.

As views `meus_pedidos`, `meu_estoque` e `receita_mensal` expõem tudo em colunas SQL comuns, para consultar direto no Supabase.

## App instalável (PWA)

Servido por HTTPS, instala na tela inicial e abre em tela cheia, sem barra de navegador:

- **Android/Chrome** — o botão "Instalar app" aparece no cabeçalho quando o navegador oferece a instalação; também funciona pelo menu ⋮ → *Adicionar à tela inicial*.
- **iPhone/Safari** — Safari não oferece prompt: use *Compartilhar* → *Adicionar à Tela de Início*.

O service worker (`sw.js`) usa **rede primeiro** para o HTML, com o cache como reserva — assim uma versão publicada chega na próxima abertura com internet, e o app continua abrindo offline com a última que funcionou. Ícones e manifesto vêm do cache. Como os dados vivem em `localStorage` e IndexedDB, tudo funciona sem sinal depois da primeira abertura.

Abrindo o arquivo direto (`file://`) o navegador não permite service worker: nesse caso é uma página comum, sem instalação.

Feita para quem imprime peças coloridas em impressora com sistema multicor (AMS/ACE), onde a purga de troca de cor costuma pesar tanto quanto a própria peça.

## O que ela calcula

Custo real por peça, item por item:

| Linha | Como sai |
|---|---|
| Filamento na peça | gramas do fatiador × preço do kg |
| Purga / desperdício | gramas da torre de purga × preço do kg |
| Energia | watts médios × horas × tarifa de kWh |
| Máquina | (preço da impressora ÷ vida útil) × horas + reserva de peças por hora |
| Trabalho | minutos de preparo e acabamento × valor da hora |
| Materiais e entrega | tinta, itens extras, embalagem e frete embutido rateado |
| Custos fixos e falhas | rateio dos custos mensais + reserva de impressão perdida |

E o preço de venda por:

```
preço = custo × (1 + margem) ÷ (1 − taxas)
```

A divisão é o ponto: comissão de marketplace, taxa de pagamento e imposto incidem sobre o **preço**, não sobre o custo. Somar 15% em cima do custo faz você receber menos do que planejou.

Outras regras do modelo:

- **Reserva de falha** = custo de produção × (1/(1−taxa) − 1), aplicada só sobre filamento, purga, energia e máquina — o que de fato se perde numa impressão refugada.
- **Preço de tabela** é sempre calculado para 1 unidade, com o frete inteiro quando ele é embutido. Os descontos por quantidade saem desse preço.
- **Peças por impressão** divide tempo de máquina, energia, depreciação e purga entre as unidades da mesma mesa.

## O que tem na tela

- Composição do custo em barra empilhada + tabela com valores e percentuais
- Composição do preço: quanto é custo, quanto é taxa, quanto sobra
- Lucro por hora de máquina — a métrica que decide quais encomendas aceitar
- Três faixas de desconto por quantidade, com a margem resultante em cada uma
- Frete por conta do cliente, embutido (frete grátis) ou retirada
- Teste reverso: "se eu cobrar R$ X, quanto sobra?"
- Alertas automáticos: prejuízo, margem abaixo de 10%, purga maior que a peça, frete grátis comendo a margem
- Biblioteca de peças salvas, exportação/importação em JSON e orçamento pronto para copiar
- **Orçamento em PDF** em folha A4, com logo e foto do produto, para enviar ao cliente

## Pedidos e painel

A segunda aba é o controle do negócio. Cada cálculo pode virar um **pedido**, que congela os números do momento (receita, custo por categoria, horas de máquina, depreciação) — mexer no preço do filamento depois não reescreve o histórico.

Status: em negociação → aguardando pagamento → pago, mais cancelado. Só o que está **pago** entra na receita; o resto aparece como pipeline.

Indicadores do mês:

| Métrica | Como sai |
|---|---|
| Receita recebida | soma dos pedidos pagos |
| Lucro bruto | receita − custo de produção − seu trabalho |
| Lucro líquido | lucro bruto − taxas − custos fixos e reserva de falhas |
| Margem líquida | lucro líquido ÷ receita |
| Retorno sobre o custo (ROI) | lucro líquido ÷ tudo que foi gasto |
| Payback da máquina | lucro líquido acumulado ÷ investimento |

Mais: gráfico de receita dos últimos 6 meses, composição da receita do mês, pipeline em aberto, e a divisão do lucro entre reserva para refazer peça, reinvestimento e o que sobra para você — tudo em percentuais que você define.

## Avisos

Central de alertas derivada dos pedidos e do estoque — nada fica gravado como "aviso", tudo é recalculado. O contador aparece na barra de abas, visível de qualquer tela.

O cálculo que importa é a **data limite para comprar filamento**, feito de trás para frente:

```
comprar até = entrega − envio − produção − chegada do filamento
```

Produção sai do tempo de impressão do pedido, a uma jornada de 8 h por dia. Exemplo real: entrega em 15 dias, 16 h de impressão, fornecedor em 7 dias e envio em 5 → o filamento precisa ser pedido em até 1 dia.

Alertas gerados:

| Tipo | Quando |
|---|---|
| Pedido atrasado | prazo venceu e não foi entregue |
| Entrega próxima | dentro da antecedência configurada (crítico com 2 dias ou menos) |
| Comprar filamento | data limite a 3 dias ou já vencida |
| Filamento acabado / acabando | rolo zerado ou abaixo do mínimo |
| Estoque não cobre os pedidos | soma das gramas em aberto maior que o estoque |
| Proposta parada | em negociação há 7 dias ou mais |
| Pagamento pendente | aguardando há 5 dias ou mais |

Cada aviso pode ser silenciado por 5 dias; depois volta se ainda fizer sentido. O status **entregue** encerra os avisos do pedido — e conta como receita no painel, junto com **pago**.

## Estoque e cores

Cadastro de rolos: cor, nome, tipo, marca, gramas restantes e preço do quilo. Resumo com total em kg, valor parado em estoque, quantos rolos estão abaixo do mínimo e quantas cores diferentes você tem para multicor.

### Análise de foto

Sobe uma foto do personagem e a página diz quantos filamentos a peça exige, quais cores, quanto de cada uma e se você tem em estoque.

**Como funciona, sem enfeite:** é quantização de cor por k-means no espaço **OKLab**, rodando no navegador — nenhuma imagem sai do computador. Não é reconhecimento de objeto: o programa lê as cores que dominam a imagem, não entende que "aquilo é o cabelo do personagem".

- **Claridade pesa menos que matiz** (0,42) ao agrupar: sombra e brilho são iluminação, não pigmento, e sem isso uma peça vermelha vira três filamentos.
- **Fundo** modelado a partir de uma faixa de toda a borda, agrupada em até 3 tons — pega fundo com degradê ou textura, não só liso (desativável).
- Brilho estourado (L > 0,95) e sombra esmagada (L < 0,07) são descartados antes de agrupar.
- Sementes determinísticas por ponto-mais-distante no percentil 95: mesma foto, mesmo resultado, sem eleger pixel solto como cor.
- A cor de cada grupo é a **média aparada** do miolo de claridade (percentis 25–75); a média simples fica lavada pelas sombras.
- Grupos abaixo de 3% são descartados e, no automático, cores perceptualmente equivalentes são fundidas — inclusive cinzas de claridade próxima.
- Comparação com o estoque usa distância perceptual cheia: ΔE ≤ 10 é "tem", até 22 é "só parecida".
- As gramas por cor saem do peso da peça na calculadora, rateado pela fatia de pixels.
- Acima de 4 cores, avisa que o ACE trabalha com 4 por vez.

Quando o automático erra, dá para corrigir: **clicar na foto** fixa aquela cor como filamento (conta-gotas) e o **×** descarta uma cor que era sombra. Os percentuais são recalculados reatribuindo todos os pixels à paleta corrigida.

Um botão desconta do estoque as gramas estimadas de cada cor.

## Ajustar a foto

Ao escolher a foto de um produto ou a capa de uma categoria, abre um ajuste antes de salvar. **Arraste para posicionar, use o controle para aproximar** — o quadro na tela é o mesmo quadro da vitrine, então o que estiver dentro é o que vai aparecer.

Dois atalhos:

- **Preencher o quadro** — a foto cobre tudo, sem borda. É como abre por padrão, e o que a maioria das fotos pede.
- **Caber inteira** — mostra a peça do topo à base, com fundo branco nas laterais. Use quando cortar qualquer pedaço estragaria a peça.

A saída é sempre quadrada, em 1600 px. Isso resolve o desalinhamento da vitrine: foto em pé e foto deitada acabam ocupando o mesmo espaço, e nenhuma delas perde a cabeça no corte.

Não dá para arrastar a peça para fora do quadro: quando a foto chega na borda, ela trava.

## Cupons da loja

Botão **Cupons da loja**, na aba Catálogo. Dali você cria, liga, desliga e exclui cupons sem tocar em SQL.

Três tipos:

- **Frete grátis** — zera o frete
- **Desconto em %** — abate uma porcentagem dos itens (o frete continua)
- **Desconto em R$** — abate um valor fixo

Cada um aceita **compra mínima**, **validade** e **limite de usos**. A coluna *Usos* mostra quantas vezes já foi aplicado.

**Desligar** para de aceitar o cupom mas mantém o histórico. **Excluir** apaga de vez, e quem tentar usar recebe "cupom não encontrado" — prefira desligar quando for uma pausa.

Quem confere se o cupom vale é o banco, no momento do pedido, com o subtotal que ele mesmo calcula. Editar a tela não gera desconto.

## Publicar na loja

Cada produto do catálogo tem uma caixa **Publicar na loja**. Marcada, a peça passa a aparecer no site da Moldarte 3D — com nome, descrição, categoria, foto, tamanhos e preços. Ao marcar, aparecem dois campos ao lado: **prazo de produção**, em dias úteis, e **estoque**.

O endereço da peça no site (`/produto/dragao-articulado`) é gerado do nome na primeira publicação e **não muda mais**: renomear a peça depois não quebra um link que já foi divulgado.

Peça no modo **sob consulta** entra na loja sem botão de compra — no lugar dele vai um "Pedir orçamento". Cópias vinculadas não são publicadas: virariam o mesmo produto duas vezes, com endereços diferentes.

Desmarcar tira a peça do ar na sincronização seguinte.

### Como funciona por baixo

O catálogo inteiro sobe como um documento só, então liberar a leitura dele exporia junto o que não foi publicado: rascunho, preço em estudo, produto fora do ar. Por isso publicar grava **uma linha por produto** numa coleção separada (`loja`), contendo apenas o que a vitrine mostra. A regra de segurança abre exatamente essa coleção para quem não tem login — pedidos, rolos de filamento, configurações e clientes continuam trancados.

As fotos dos produtos publicados sobem para o **Storage**, e não como base64 dentro do banco: numa vitrine elas precisam de cache de CDN. Cada uma só é reenviada quando muda de verdade.

> **Antes da primeira publicação**, rode o arquivo `supabase-loja.sql` no SQL Editor do projeto. Ele cria a regra de leitura pública e o espaço das fotos. Sem ele o resto continua sincronizando normalmente — só as fotos da loja não sobem, e o aviso aparece no console do navegador.

## Catálogo

Terceira aba. Categorias livres (Anime, Games, Marvel, DC, Carros…), cada uma com capa horizontal ou vertical e quantos produtos você quiser. Cada produto tem foto, descrição e uma lista de tamanhos com preço próprio — 15 cm, 20 cm, 25 cm, 30 cm — e três modos de exibição: **a partir de** (mostra o menor preço), **preço único** ou **sob consulta**.

O botão gera um PDF de várias páginas: capa com sua logo, uma página por categoria com os produtos em grade de duas colunas, e uma página final de condições.

### Descrição automática

Cada produto tem um botão que escreve a descrição sozinho. **Não é IA e não enxerga o personagem:** o que ele sabe vem do nome digitado, do nome da categoria e dos tamanhos cadastrados.

Além de nome e tamanhos, cada produto tem três campos que alimentam o texto: **universo/jogo**, **estilo** (25 opções) e **características**.

O texto monta até seis partes a partir de bancos de frases:

1. **Abertura** — quatro bancos de 25 frases cada, escolhidos pelo que existe no produto: por *universo/jogo* quando preenchido, por *adaptação* quando a categoria é de releituras, por *personagem* no caso geral, e um repertório temático próprio para categorias que não falam de personagem (decoração, pets, carros, esporte).
2. **Estilo** — uma frase específica para cada um dos 25 estilos.
3. **Material e características** — em tom afirmativo. Sem ressalva sobre linhas de camada: catálogo é peça de venda, e o lugar de alinhar expectativa é o campo de observações do orçamento.
4. **Tamanhos** — quando todos compartilham a unidade, ela aparece uma vez só: `15 cm, 20 cm e 25 cm` vira `15, 20 e 25 cm`.
5. **Complemento** — 25 frases curtas, usadas só quando não houve frase de estilo, que cumpre o mesmo papel.
6. **Convite ao orçamento** — para quem quer um tamanho fora da tabela.

As frases usam variáveis `{{nome}}`, `{{jogo}}`, `{{estilo}}`, `{{caracteristicas}}` e outras; frase cujo campo esteja vazio é descartada na escolha, então nunca sai texto com lacuna. A seleção vem de um hash do nome do produto — cada peça recebe um texto diferente, e apertar de novo gira para outra variação.

Produtos se movem entre categorias e sobem/descem dentro delas. Duplicar oferece dois modos:

- **Cópia independente** — vira outro produto, com preços e descrição próprios.
- **Cópia vinculada** — o mesmo produto aparecendo em duas categorias; nome, preços e foto vêm do original, então editar num lugar muda nos dois.

Apagar um original que tem cópias vinculadas não deixa nada órfão: as cópias são materializadas como produtos independentes, com os dados preservados, antes da exclusão.

As imagens do catálogo ficam em **IndexedDB**, não no `localStorage` — dezenas de fotos passam muito dos ~5 MB que o `localStorage` oferece. Textos e preços continuam no `localStorage`. O backup JSON leva as duas coisas.

## O orçamento em PDF

Não usa biblioteca de PDF: a página monta uma folha A4 real e chama a impressão do navegador, onde o destino "Salvar como PDF" gera o arquivo. O texto sai vetorial e selecionável, e o nome do arquivo já vem sugerido como `Orcamento-0001-Nome-do-Cliente.pdf`.

Logo e foto do produto são redimensionadas no navegador antes de guardar (logo em PNG até 700 px para manter transparência, foto em JPEG até 1100 px) e ficam embutidas como data URI no `localStorage`, junto do resto dos dados.

A folha mostra o preço cheio na linha do item e o desconto por quantidade abatido nos totais — o percentual anunciado bate exatamente com o valor abatido, porque só o preço de tabela é arredondado e todo o resto deriva dele.

Os dados ficam no `localStorage` do navegador. Nada é enviado para lugar nenhum.

## Acessibilidade

A paleta das séries do gráfico foi validada para deuteranopia, protanopia e tritanopia (separação mínima ΔE ≥ 8 em OKLab entre fatias vizinhas), em tema claro e escuro. Nenhuma informação depende só da cor: toda fatia aparece também na tabela com valor e percentual.

## Ajuste antes de usar

Os valores que abrem na tela são estimativas. Troque pelos seus:

- preço do quilo do filamento — o de reposição, com frete
- tarifa de kWh, que está na sua conta de luz
- consumo médio em watts (um medidor de tomada resolve)
- investimento na máquina e vida útil estimada
- valor da sua hora de trabalho
