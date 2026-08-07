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
