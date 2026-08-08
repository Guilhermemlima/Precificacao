# Precifica 3D

Calculadora de precificação para impressão 3D sob encomenda. Página única em HTML, sem dependências, sem build e sem servidor: baixe `index.html` e abra no navegador, ou publique a pasta em qualquer hospedagem estática (Vercel, Netlify, GitHub Pages) sem nenhuma configuração.

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

## Catálogo

Terceira aba. Categorias livres (Anime, Games, Marvel, DC, Carros…), cada uma com capa horizontal ou vertical e quantos produtos você quiser. Cada produto tem foto, descrição e uma lista de tamanhos com preço próprio — 15 cm, 20 cm, 25 cm, 30 cm — e três modos de exibição: **a partir de** (mostra o menor preço), **preço único** ou **sob consulta**.

O botão gera um PDF de várias páginas: capa com sua logo, uma página por categoria com os produtos em grade de duas colunas, e uma página final de condições.

### Descrição automática

Cada produto tem um botão que escreve a descrição sozinho. **Não é IA e não enxerga o personagem:** o que ele sabe vem do nome digitado, do nome da categoria e dos tamanhos cadastrados.

O texto monta quatro partes a partir de bancos de frases:

1. **Gancho** — muda conforme o tema da categoria (anime, games, heróis, carros, desenho, terror, decoração).
2. **Corpo técnico** — material e acabamento, em tom afirmativo. Nada de ressalva sobre linhas de camada ou variações do processo: catálogo é peça de venda, e o lugar de alinhar expectativa é o campo de observações do orçamento.
3. **Tamanhos** — quando todos compartilham a unidade, ela aparece uma vez só: `15 cm, 20 cm e 25 cm` vira `15, 20 e 25 cm`. Unidades diferentes são mantidas como estão.
4. **Convite ao orçamento** — para quem quer um tamanho fora da tabela.

A escolha vem de um hash do nome do produto, então cada peça recebe um texto diferente; apertar de novo gira para outra variação.

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
