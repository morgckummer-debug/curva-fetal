# curva-fetal

Site estático de página única (`index.html`), sem build step. Login/dados ficam
num backend Supabase (ver `<meta ... Content-Security-Policy ...>` no `<head>`
para a URL do projeto e `supabase/schema.sql` para o esquema).

## Branch publicada pelo GitHub Pages — IMPORTANTE

Desde 2026-08-01 a `main` é a fonte única: recebeu todo o conteúdo que antes só
existia em `claude/fetal-clinic-security-audit-c4ajnl` (login/Supabase, backup,
importação etc.) e o GitHub Pages **deveria** publicar a partir dela.

Antes disso, o Pages publicava de `claude/fetal-clinic-security-audit-c4ajnl` —
uma branch completamente diferente da `main`, com histórico próprio — e isso
causou bastante confusão (mudanças na `main` não apareciam no site publicado).
**Não assuma que `main = produção` sem checar.** Confirme a branch de origem
real olhando os runs do workflow "pages build and deployment" (`head_branch`
dos runs mais recentes). Se `head_branch` não for `main`, pare e avise o
usuário antes de continuar — não tente adivinhar ou aplicar merge cego entre
branches divergentes.

## Fluxo de deploy

Depois de validar uma mudança, faça merge/push direto para a branch que o Pages
publica (confirme qual é, ver acima) sem pedir confirmação a cada vez — esse é o
comportamento combinado com o usuário. O Pages atualiza em ~1 minuto após o push.

## Salvamento no Supabase: fila, não disparo solto

`saveDB(db)` atualiza o estado local (`_memoryDB`) de forma síncrona e enfileira a
gravação (`_syncToSupabase()` → `_runSyncLoop()`). A fila garante **uma requisição
por vez**, repete até 4 vezes com espera crescente se a rede falhar, mostra o selo
`#save-status` ("Salvando…" / "✓ Salvo" / "⚠ Não salvo") e o `beforeunload` avisa
antes de fechar/recarregar com algo pendente. `doLogout()` também pede confirmação.

Antes (até 2026-08-22) cada `saveDB()` disparava um upsert solto e não aguardado:
um F5 ou uma navegação logo depois de cadastrar cancelava a requisição no meio e o
dado sumia em silêncio (ver conversa de 2026-08-01 sobre pacientes de teste que
"sumiram" após reload). Se for mexer nessa área, não volte a disparar upsert fora
da fila — `_syncPending` é o que segura o `beforeunload` e o que impede
`_bootstrapFromSupabase()` de sobrescrever alteração ainda não gravada.

## Backup: três camadas, e nenhuma delas é o Supabase

O plano Free do Supabase **não faz backup automático nenhum** (backup diário só do
Pro em diante). Isso é o pano de fundo de tudo nesta seção — não existe rede de
proteção do lado do servidor.

1. **Snapshot automático** (`_enviarSnapshot`, migração 006). Uma foto do DB em
   `backups/{user_id}/{AAAA-MM-DD}.json`, no Storage do próprio Supabase: bucket
   privado, uma policy por operação amarrando a primeira pasta do caminho ao
   `auth.uid()`. Um arquivo por dia com alteração; o do dia corrente é reescrito
   (upsert) a cada 5 min enquanto ela trabalha, os anteriores nunca são tocados.
   Disparado por `_agendarSnapshot()` em dois pontos: no fim do `_runSyncLoop`
   (depois de o servidor confirmar a gravação) e no fim do bootstrap. O segundo
   não é redundante — sem ele, quem abre o app, confere uma ficha e fecha passa o
   dia sem cópia, e um Storage vazio não distingue "não precisou" de "quebrado". Cobre sobrescrita por bug, exclusão
   acidental e colisão com o editor de laudos. Não cobre perder o projeto inteiro.
2. **Arquivo baixado** (`exportData`). A única cópia fora do Supabase — a única
   que sobrevive se o projeto for perdido. Depende de clique, por isso a faixa
   `#aviso-backup` cobra depois de 7 dias (`renderAvisoBackup`, chamada no topo de
   `renderRecentPatients`). A data fica em `localStorage`, então é por aparelho.
3. **Restauração** (`restaurarSnapshot`). Sem isso as outras duas não valem nada.

Dois cuidados que não são detalhe:

- **Falha de snapshot é silenciosa para o fluxo, visível na tela de cópias.** Não
  interrompe o trabalho (o dado já está gravado pela fila do saveDB), mas
  `_snapshotResultado` guarda o motivo e `_renderStatusSnapshot` o mostra, com um
  botão `forcarSnapshot()` para tentar na hora. Só console não serve: no celular
  ninguém vê, e um backup que não está sendo feito é idêntico a um que está.
- **`_enviarSnapshot` recusa DB vazio.** Se o bootstrap falhar e a memória zerar,
  gravar isso por cima da foto de hoje apagaria justamente a cópia que serviria
  para recuperar.
- **Restaurar mescla, não substitui** (`_mesclarSnapshot`). As fichas do snapshot
  voltam por cima das atuais por id; o que foi criado depois continua. É o que
  acontece de fato no servidor — `_pushToSupabase` faz upsert, nunca delete — então
  memória e banco contam a mesma história. Trocar o DB em memória pelo snapshot
  inteiro fazia a paciente cadastrada depois sumir da tela até o próximo F5.

O bucket fica sem `allowed_mime_types` de propósito: o SDK envia o arquivo como
multipart e basta o Storage registrar outro tipo para recusar o upload — trocaria
proteção nenhuma (só este app grava ali) por backup inexistente sem ninguém ver.

Datas usam `_hojeISO()` (dia local), não `toISOString()` cru: em UTC-3 todo
trabalho feito depois das 21h cairia no arquivo do dia seguinte.

## Relatório PDF: abre pra imprimir na hora, e fica arquivado pra segunda via

`confirmarGerarPDF()` não baixa mais um `.html` pra clicar em Ctrl+P na mão —
abre uma aba nova com `window.open(url, '_blank')` (a URL de um Blob criado na
hora) e o próprio documento exportado tem `<body onload="window.print()">`,
então o diálogo de impressão já aparece sozinho. O `window.open` tem que ser
síncrono, sem `await` antes: é o clique no botão que autoriza a aba nova, e um
`window.open` depois de uma espera vira pop-up bloqueado.

Cada geração também sobe uma cópia do HTML pro bucket privado `relatorios`
(migração 008, mesmo padrão de RLS por `auth.uid()` da 006) em
`relatorios/{user_id}/{gestacao_id}/{data}_{hora}.html` — um arquivo por
emissão, não reescrito como o snapshot do dia. É a "segunda via": se a
paciente perder a via impressa, `abrirRelatoriosModal()` lista os relatórios
daquela gestação e reabre qualquer um por URL assinada (`createSignedUrl`,
bucket privado) — o mesmo HTML, com o mesmo auto-print. O upload é
fire-and-forget (`_salvarRelatorioGerado`, mesmo espírito do `_enviarSnapshot`):
nunca atrasa nem trava a impressão, que já está acontecendo antes dele rodar.

## "JWT issued at future": relógio, não dado

`PGRST303` vem de desencontro de relógio dentro do próprio Supabase — o GoTrue
carimba o token com uma hora que o PostgREST considera futura e recusa a leitura.
É transitório e do lado do servidor; não há nada a corrigir no app nem nos dados.
O `catch` do bootstrap detecta e diz isso, porque a mensagem crua na tela de quem
guarda prontuário lê como "perdi tudo". O guarda do `_enviarSnapshot` contra DB
vazio é o que impede o estrago de virar permanente: com o bootstrap falhando, a
memória fica zerada e sem ele a foto de hoje seria sobrescrita com nada.

## Projeto Free pausa sozinho

Projeto no plano gratuito pausa depois de ~1 semana sem acesso, e o app só via um
erro de rede genérico. "Não consegui carregar seus pacientes" depois de uma viagem
é indistinguível de "sumiu tudo" para quem está do outro lado. O `catch` do
`_bootstrapFromSupabaseImpl` detecta resposta ausente (`Failed to fetch`, 502/503/
504/544) e diz o que provavelmente é, com o caminho para despausar. O SDK repete a
requisição algumas vezes antes de desistir: a mensagem leva uns 10 s para aparecer.

## Ordem das listas vem do banco, não do array

`select()` sem `.order()` no PostgREST devolve as linhas em ordem física, que muda
a cada gravação — e `_syncToSupabase` reescreve as três tabelas inteiras a cada
save. Por isso os selects do bootstrap usam `.order('id')` e `renderRecentPatients()`
ordena por `id` decrescente antes de cortar em 8. Não confie na ordem do array
`DB.patients` para saber quem foi cadastrada por último.

## Duas aplicações escrevem nas mesmas tabelas

O editor de laudos (repo `morgckummer-debug/laudos-dramorgana`, arquivos
`obstetrico.html` e `obstetrico-1trimestre.html`) grava direto em `patients` e
`exams` deste mesmo Supabase, usando o CPF como chave para achar a paciente. Toda
mudança em como este app grava CPF, id ou soft-delete precisa ser espelhada lá —
não existe código compartilhado entre os dois repos.

- **Fetos: A/B na gemelar, A/B/C na trigemelar.** `fetosDaGestacao(g)` é a
  lista; ninguém pergunta `tipo_gestacao === 'gemelar'` direto. O laudo manda o
  Feto 1 como `'A'`, o 2 como `'B'`, o 3 como `'C'`, e a corionicidade segue o
  número de fetos nos dois lados (tricoriônica só com três). Isso depende da
  migração 005, que soltou os checks de `exams.feto`, `tipo_gestacao` e
  `corionicidade` — sem ela o insert do terceiro feto falha.
- **CPF: sempre `000.000.000-00`.** Formato pontuado é a forma canônica dos dois
  lados. Até 2026-08-22 o laudo obstétrico gravava só os 11 dígitos e a mesma
  paciente virava duas linhas. `_bootstrapFromSupabase()` normaliza na leitura,
  a migração 003 conserta as linhas antigas e a 004 põe unique em
  `(user_id, cpf)` — para o desalinhamento voltar como erro, não em silêncio.
- **Ids: faixas separadas.** Este app escolhe o id (maior id + 1) e grava por
  upsert; o editor insere sem id e deixa a identity gerar. A migração 004 põe a
  identity para começar em 1.000.000 e `_proximoIdLocal()` só conta os ids abaixo
  disso. Sem essa separação, um insert do editor colide com id existente e o
  upsert daqui (que reescreve as tabelas inteiras) sobrescreve a linha do editor.
- **Discordância de peso: três faixas nos dois lados.** Abaixo de 20% é o
  esperado, 20 a 25% pede vigilância, acima de 25% é critério de CIUR seletivo
  (que fecha sozinho — o outro braço é um feto abaixo do P10). O editor tinha um
  corte só, em 20%, até 2026-09-20: uma gemelar de 27% saía de lá com a mesma
  frase de uma de 21%, enquanto o relatório daqui já dizia "critério de CIUR
  seletivo". Dois documentos da médica, sobre a mesma paciente, com gravidades
  diferentes. Corrigido nos dois (`_DISCREP_FAIXA` aqui,
  `impDiscordanciaVigilancia` lá). A fórmula `(maior − menor) / maior` sempre
  bateu. O termo é **discordância** nos dois lados, não "discrepância" nem
  "diferença".
- **`au_fluxo` aceita `intermitente` (iAREDF) desde 2026-09-20.** A coluna é
  `text` sem CHECK e o editor não a escreve, então o valor novo não precisou ser
  espelhado lá — mas se um dia ele passar a escrever Doppler de umbilical,
  precisa conhecer esse valor.
- **Lixeira:** `excluido_em` preenchido significa fora de toda leitura normal. As
  buscas do editor filtram `.is('excluido_em', null)` pelo mesmo motivo, e o
  unique da 004 é parcial (`where excluido_em is null`) para não impedir o
  recadastro de um CPF que foi para a lixeira.

## Diagnóstico de crescimento: Delphi, mas não só Delphi (e nunca sem olhar a IG)

`calcDiagnosticoFGR()` classifica adequado/PIG/GIG/RCIU precoce/RCIU tardio, e
`_condutaDiagnostico()` escreve a conduta. As duas telas que mostram isso — o
Resumo (`_buildSummaryHtml`) e o relatório/PDF (`computeImpressaoDiagnostica`) —
chamam as **mesmas** funções (`_critItemsDiagnostico`, `_condutaDiagnostico`,
`_fonteDiagnostico`). Antes eram duas cópias literais da lista de critérios e da
tabela de conduta; mexer numa e esquecer a outra fazia a tela e o papel
discordarem na frente da paciente. Não volte a duplicar.

O **nome** de cada diagnóstico entrou na mesma regra em 2026-09-20: vivia
duplicado literal em `DX_CFG` (faixa da tela) e `DX_META` (relatório). Agora sai
de `_DX_NOME`, por `_dxNome(diagnostico, gestacao)` — que ainda decide pelo tipo
de gestação, ver a seção de gemelares abaixo. Os dois objetos continuam
existindo porque um carrega cor e borda e o outro só o ícone; o texto, não.

RCIU não escreve mais a faixa de semanas no nome (`RCIU Precoce`, não `RCIU
Precoce (< 32 semanas)`): a IG está no cabeçalho do relatório e na coluna IG do
histórico, "precoce"/"tardio" já diz isso, e o parêntese colidia com o do
percentil na Conclusão (`RCIU Precoce (< 32 semanas) (P4)`). O estágio continua
na linha seguinte — é ele que precisa ser lido junto do diagnóstico.

**IP das uterinas > P95 conta como critério menor também depois de 32 semanas.**
O texto estrito do Delphi 2016 só lista as uterinas no RCIU *precoce*; por causa
disso uma paciente de 38 semanas com PFE < P10 **e** IP-UtA > P95 saía como
"PIG". São dois critérios — um de tamanho e um de Doppler — e a leitura clínica
é restrição. Quem embasa é o protocolo de Barcelona (Figueras & Gratacós, Fetal
Diagn Ther 2014), o mesmo do estadiamento que o app já usava: o estadiamento já
contava `utAboveP95` como Estágio I, ou seja, o app reconhecia o achado para
estadiar e não para diagnosticar. Por isso a linha de atribuição embaixo do
diagnóstico (`_fonteDiagnostico`) diz "Delphi 2016 + protocolo Barcelona" a
partir de 32 semanas — creditar ao consenso um critério que ele não tem seria
errado. Se um dia isso voltar ao Delphi puro, é tirar `utAboveP95` de uma linha
só em `calcDiagnosticoFGR` e ajustar `_fonteDiagnostico` junto.

**Nenhum intervalo de reavaliação passa do fim da gestação.** As condutas eram
strings fixas ("Reavaliação em 4 semanas") e em 38 semanas marcavam um exame
para depois do parto. `_intervaloAteOTermo(gaW, semanas)` encurta o intervalo
para caber até 40 semanas e devolve `null` quando não cabe mais nenhum — aí o
texto passa a ser obstétrico (definir a resolução), não ultrassonográfico. No
RCIU a conduta também diz o alvo de resolução do estágio (Barcelona/FIGO:
I ≥ 37s, II ≥ 34s, III ≥ 30s, IV ≥ 26s) e avisa quando a IG já o alcançou.
Qualquer conduta nova entra por essa mesma porta: intervalo fixo em texto puro
é o bug de 2026-09-19 voltando.

## PIG constitucional, notas clínicas e o intervalo mínimo do cruzamento

Revisão de 2026-09-19 contra material de RCIU trazido pela médica. Quatro
mudanças, todas no mesmo eixo: o app dizia o diagnóstico e calava o resto.

- **`_notasDiagnostico(dx)` existe para não emendar tudo na conduta.** A conduta
  é lida em voz alta na consulta e cabe num cartão estreito do relatório
  gemelar (ver `_buildRelGemelarPaginaHtml`); três frases a mais ali empurram o
  histórico para a segunda folha. As notas são um array à parte, renderizado no
  Resumo em tela, na faixa de status do relatório e na conclusão editável de
  gestação única — de propósito **não** no cartão por feto da gemelar.
- **RCIU precoce sugere investigação genética e infecciosa.** Até 20% dos casos
  antes de 32 semanas têm causa cromossômica/genética, não placentária, e o
  Doppler não levanta essa hipótese sozinho. Sai como "a critério do médico
  assistente": quem indica a amniocentese é quem conduz o pré-natal.
- **PIG constitucional é nomeado quando o padrão fecha** (`_trajetoriaPIG`):
  percentil ≤ 20 em todos os exames, janela ≥ 28 dias entre o primeiro e o
  último, e nenhum Doppler alterado em nenhuma visita. O teto é 20, não 10, de
  propósito — "sempre foi pequeno" é a faixa se manter, não estar abaixo do
  corte em toda visita. Dois cuidados: exige que **alguma** visita tenha medido
  Doppler (exame sem Doppler não é Doppler normal, e tratar dado ausente como
  tranquilidade é exatamente o erro que essa nota não pode cometer), e o texto
  diz "padrão sugestivo de", nunca o diagnóstico, porque a outra metade da
  confirmação é a avaliação materna, que este app não vê.
- **Cruzamento de 2 quartis exige 14 dias entre os exames comparados.** A CA tem
  erro de medida de 5–7%; dois exames com poucos dias de diferença faziam o
  ruído parecer queda de trajetória. Virou risco real quando o IP das uterinas
  entrou na contagem: com CA/PFE < P10, um cruzamento falso sozinho fecha RCIU
  tardio. Compara com o exame válido mais antigo que respeite o intervalo, não
  com o anterior imediato — a queda que o critério procura é da trajetória.

Onde o app diverge de propósito do material: cadência do Estágio I (o material
sugere semanal para CPR alterada com AU normal; aqui são 2–3×/semana, política
da médica). Ficaram de fora por decisão dela: usar ILA/maior bolsão no
diagnóstico e a ressalva de dependência da curva no percentil limítrofe.

## Velocidade de crescimento: pelo percentil, e só com 14 dias

Revisão de 2026-09-20. A Conclusão dizia ", com trajetória estável e Doppler
dentro da normalidade" sempre que houvesse 2+ exames e nenhum achado — ou seja,
uma paciente com duas visitas separadas por **uma semana** recebia "trajetória
estável" sobre um intervalo em que ninguém vê trajetória nenhuma.

- **Lida pelo percentil, não em g/semana.** O ganho ponderal foi calculado,
  conferido contra a mediana da própria curva e **descartado**: "150 g/semana"
  obriga quem lê a ter a curva de Hadlock na cabeça. O percentil já é o peso
  comparado com o esperado para a IG — se ele se manteve por 14+ dias, a
  velocidade foi a da curva, por definição. É também a pergunta que o obstetra
  faz ("caiu de percentil?"). Se um dia o número em gramas voltar à discussão, o
  lugar dele é uma coluna do histórico biométrico, onde a queda entre visitas
  aparece sozinha — não a Conclusão.
- **Tolerância de 20 pontos de percentil, para cada lado** (`_VELOCIDADE_
  TOLERANCIA_PERCENTIL`). O PFE combina quatro medidas e erra 10–15%, então um
  feto no P45 oscilando entre P25 e P65 mudou de ruído, não de trajetória. Não
  pode ser "não caiu nada".
- **14 dias, da mesma constante do cruzamento de quartis**
  (`_INTERVALO_MIN_CRESCIMENTO_DIAS`). Era um `const` local dentro de
  `calcDiagnosticoFGR`; virou compartilhada para não existirem dois 14 soltos.
  Compara com o exame válido **mais antigo** que respeite o intervalo, não com o
  anterior imediato — mesma escolha e mesmo motivo do cruzamento.
- **Três fechos, em `_fraseTrajetoriaTxt`**, e o quarto caso é silêncio: dentro
  da tolerância → "com velocidade de crescimento dentro do esperado e Doppler
  dentro da normalidade"; acima → "com aceleração do crescimento"; **sem
  intervalo de 14 dias → só o Doppler**. `_velocidadeCrescimento` devolvendo
  `null` é "o app não tem base para dizer nada", nunca "está tudo bem".
- **Queda acima da tolerância tem linha própria** (`_notaDesaceleracaoTxt`,
  texto da médica): "Nota-se desaceleração da velocidade de crescimento[ no Feto
  2], sem critérios de CIUR no momento." A segunda metade só é verdade porque a
  nota só sai com diagnóstico `adequado` — se um dia sair em outro, vira mentira.

## Gemelar não é gestação única duas vezes

Revisão de 2026-09-20, com material de CIUR trazido pela médica. O app aplicava
o Delphi feto a feto e chamava de **PIG** um feto pequeno dentro de uma gemelar
— que é a leitura de um feto sozinho. **O consenso Delphi 2016 é de gestação
única.** Essa é a origem da confusão, e vale para quem for mexer aqui.

- **Em gestação múltipla o nome é CIUR seletivo, não PIG** (`_DX_NOME_MULTIPLA`,
  aplicado por `_dxNome`). Vale para mono **e** dicoriônica: o dano que o nome
  corrige existe igual nas duas, e a dicoriônica é a mais frequente. O que muda
  com a corionicidade são os **critérios** e a **conduta** — é aí que ela entra,
  não no nome.
- **A corionicidade sai impressa no relatório** (`_CORIO_EXTENSO`, no bloco de
  identificação). O papel podia imprimir "CIUR seletivo" sem dizer se era mono
  ou di, e é isso que decide o que o obstetra faz: na dicoriônica o mecanismo é
  insuficiência placentária, na monocoriônica é divisão desigual da placenta e
  anastomoses, com deterioração abrupta. Mesmo diagnóstico, dois prognósticos.
  A tela já mostrava a sigla (`CORIO_LABEL`); o papel não mostrava nada.
- **`_fonteDiagnostico` diz o que foi calculado, não o que soa bem.** Num feto
  de gemelar ela não credita Delphi — nem 2016 (é de única) nem 2019 (o app não
  calcula os 2-de-4 dele). Diz "critérios de gestação única aplicados por feto",
  porque é isso que acontece. Mesmo princípio da linha das uterinas depois de 32
  semanas. Na monocoriônica ela ainda avisa, na tela, que Gratacós não é
  calculado — para a médica não supor que o app olhou.
- **Classificação de Gratacós** (`_gratacosTipo`, `_GRATACOS_CFG`): Tipo I
  diástole positiva persistente, II ausente/reversa persistente, III iAREDF. Só
  em monocoriônica, e só para o feto **restrito** — o tipo é dele, não da
  gestação. `null` é "não classificado", **nunca Tipo I**. O Tipo III depende do
  valor `intermitente` em `au_fluxo`, criado junto; iAREDF também entrou no
  `auDiastoleZero` e no estadiamento de Barcelona, senão o achado mais grave da
  monocoriônica seria o único a não disparar nada.
- **Barcelona continua aparecendo na monocoriônica de propósito**, ao lado de
  Gratacós e não no lugar dele. A conduta (`_condutaDiagnostico`) ainda é
  escrita por estágio de Barcelona, e tirar Barcelona da tela deixaria a conduta
  citando um estágio que ninguém vê. **Pendência aberta:** as três condutas por
  tipo de Gratacós, que são texto clínico da médica. Com elas, Barcelona sai da
  monocoriônica e fica onde é dele — gestação única e dicoriônica.

## ACM < P5, e a trava que ela obrigou a criar

Também de 2026-09-20. A centralização fetal (brain-sparing) é critério formal do
Delphi de **gestação única** e pesa no CIUR tardio; o z-score da ACM já era
calculado e não entrava em diagnóstico nenhum.

- **Só em gestação única.** Nos gemelares, sobretudo monocoriônicos, a ACM não
  entra nos critérios de sFGR (PFE < P3, ou combinação de PFE < P10, CA < P10,
  discordância ≥ 25%, IP da AU > P95): lá o mecanismo não é insuficiência
  placentária progressiva e a centralização não conta a mesma história. Foi por
  isso que `calcDiagnosticoFGR` passou a receber a gestação.
- **Pelo menos um critério tem de ser de crescimento.** Essa linha parece zelo
  excessivo e não é — **não a remova sem entender o que ela evita.** O
  invariante vinha de graça: dos três critérios do CIUR tardio, dois eram de
  tamanho/trajetória e um só de Doppler, então era impossível chegar a 2 sem
  tocar no crescimento. A ACM virou um **segundo** critério de Doppler, e sem a
  trava um feto no P50 com centralização e CPR baixo fecharia "RCIU tardio" sem
  nenhuma alteração de crescimento — que é achado de Doppler isolado, não
  restrição. O achado continua aparecendo na lista de critérios; o que não
  acontece é o diagnóstico.
- Atenção ao sinal: `_z.acm` é **invertido** no `enrichExams` (IP baixo = z
  positivo), então ACM < P5 é `z > +1.645`, e não `< -1.645` como nos outros.

## Conclusão do relatório: formato definido pela médica

2026-09-20, item a item. Nenhuma destas linhas é estética.

- **Percentil colado no feto, por extenso:** "Feto 1 no percentil 20 e Feto 2 no
  percentil 11" (`_fetoPercentilTxt`). Entre parênteses depois do diagnóstico
  ele encostava no parêntese que vários rótulos já têm. Feto sem PFE **não some
  da linha** — vira "Feto 2 sem peso estimado nesta visita": o obstetra conta os
  fetos na Conclusão.
- **`adequado` não ganha rótulo.** O percentil já diz isso; "Feto 2 no percentil
  40 — Feto adequado" é a mesma informação duas vezes. Os outros viram rótulo
  curto depois do travessão, sem a expansão da sigla — que continua no card do
  feto e no Resumo em tela.
- **O critério que fechou o diagnóstico saiu da Conclusão** ("PFE < P10"). Com
  percentil, rótulo, discordância, conduta e notas na mesma lista, era a
  informação a mais que tirava o foco. Segue no card e no Resumo, e continua
  pesando em `semAchados` — feto com critério não é feto "estável".
- **O percentil sai de `impressao.efwPercentil`**, calculado do mesmo exame
  enriquecido em que o diagnóstico foi feito. O selo do card lia por conta
  própria antes; selo e Conclusão não podem discordar de um percentil.
- **Agrupamento só por diagnóstico.** A chave incluía os critérios, que não
  sendo mais impressos fariam dois grupos imprimirem linhas idênticas.

## Comentário da especialista: o único lugar que pode prescrever

Seção facultativa do relatório (`_relComentarioHtml`, 2026-09-20). Nasce vazia
no preview, nas três montagens, e **em branco não imprime nada — nem o título**
(mesma regra da coluna Colo: título com campo vazio parece que faltou
preencher).

A regra de "o relatório não prescreve" (ver colo curto, abaixo) é sobre o que o
**app gera sozinho**. Aqui é a médica escrevendo e assinando: pode dizer o que
ela quiser, conduta inclusive. Daí a faixa dourada à esquerda — separa a voz
dela do texto gerado, para quem recebe o papel. Passa pelo `_relMarcacaoHtml`
como a Conclusão.

O cabeçalho do relatório também mudou nessa conversa: o kicker diz o que o
documento **é** ("Relatório evolutivo"), não como o serviço se chama. O nome do
programa ficou no rodapé, junto da assinatura.

## Colo curto e pré-eclâmpsia são da gestação, não do feto

Achados maternos (`avaliarRiscoColoCurto`, `avaliarRiscoPreEclampsia`) entram no
relatório **uma vez por gestação**. Antes vinham de dentro do laço por feto: a
mesma medida de colo saía duas vezes no relatório gemelar e três faixas
idênticas na trigemelar, como se fossem achados diferentes. Agora a faixa é
montada fora do laço (`_buildRelAssessmentPageHtml`) e a linha de texto entra
na Conclusão, não no cartão de cada feto (`_gerarConclusaoGemelarInicial`).
Na gemelar isso também conserta uma ausência: a Conclusão — a primeira coisa
que o obstetra lê — não trazia colo curto de jeito nenhum, só os cartões.

**Formato da linha na conclusão** (`_riscoLinhaTexto`, definido pela médica em
2026-09-19): `__Colo curto__ — risco de parto prematuro (Progesterona vaginal
indicada (ISUOG 2022 / FMF), independente de antecedente obstétrico.)` — achado
sublinhado, risco em seguida, conduta entre parênteses. Sublinha só a parte
antes do travessão: é o que a vista precisa pegar primeiro numa lista de itens.
O `subtitulo` não entra (repetia a referência que a conduta já carrega — "ISUOG
2022 / FMF" saía duas vezes na mesma frase); a medida do colo, que morava nele,
está na coluna Colo do histórico. Qualquer faixa de risco nova entra na
conclusão por essa função.

**Colo curto é um rótulo só.** Abaixo de 25 mm a partir de 16 semanas, o achado
se chama "Colo curto — Risco aumentado de parto prematuro", e ponto. Havia uma escada de
três nomes que dava ao caso mais grave e ao mais leve exatamente o mesmo nome
("Colo curto" abaixo de 10 mm e entre 15–25 mm), com só o do meio como "muito
curto" — e é justamente essa palavra que o sublinhado da conclusão destaca. A
gravidade quem dá é a medida, que está na frase do relatório e na coluna Colo do
histórico. O **conteúdo** continua graduado pelos mesmos cortes de sempre (10 e
15 mm): o que se discute com 8 mm não é o que se discute com 22 mm.

**O relatório não prescreve; a tela sim.** Decisão da médica em 2026-09-19: o
laudo de ultrassom que sai da clínica não indica progesterona nem cerclagem —
isso é do obstetra que acompanha, e "Progesterona vaginal indicada" no papel lê
como invasão de conduta. `avaliarRiscoColoCurto` devolve dois textos:
`conduta` (completo, com dose e indicação, graduado por faixa) alimenta a
**tela**, que é ferramenta de trabalho e não sai da clínica; `condutaRelatorio`
alimenta o **PDF** e é um texto só, igual nas três faixas: a medida, o corte de
25 mm que ela cruza e os fatos da gestação (antecedente, progesterona em uso,
cerclagem realizada) — que são registro, já estão no prontuário, e repetidos ali
não indicam nada a ninguém. Não fecha com "Conduta a critério do obstetra
assistente": sem nenhuma recomendação antes, essa frase deixa de delimitar
competência e passa a soar como desinteresse. Um laudo que só descreve o achado
já devolve a decisão sem precisar dizê-lo.

Nenhuma recomendação entra aí — nem nomeando a terapia sem verbo prescritivo
("faixa em que se discute progesterona vaginal"), nem encaminhando
("recomenda-se avaliação obstétrica imediata"). Mesmo sem prescrever, nomear a
terapia já é opinar sobre o que não é do laudo. A gravidade continua no papel
pelo número: 8 mm e 22 mm imprimem a mesma frase com medidas diferentes, e a
coluna Colo do histórico mostra a queda entre as visitas.

Isso vale **só para o colo** — AAS das uterinas, internação e conduta de RCIU
seguem prescritivos, por decisão dela na mesma conversa. Quem lê os dois textos:
`_riscoLinhaTexto` e `_renderColoRiscoFaixaHtml` usam `condutaRelatorio ||
conduta`, então uma faixa de risco nova sem `condutaRelatorio` continua
imprimindo a conduta normal — o fallback é intencional, não esquecimento.

**`__assim__` vira sublinhado** (`_relMarcacaoHtml`), e é a única marcação
aceita. A conclusão passa por um `<textarea>` antes de imprimir: HTML digitado
ali é escapado e sairia cru no papel, então a ênfase viaja como texto puro e
vira tag só ao montar a lista. A ordem em `_relMarcacaoHtml` não é estética —
escapa primeiro, marca depois, senão um `<` digitado na conclusão vira tag de
verdade no relatório.

**Coluna `Colo` no histórico biométrico** (`_relTemColo`/`_relColoCel`, nas duas
tabelas). O valor de uma visita diz menos que a queda entre visitas, e o colo
não aparecia em nenhuma coluna do relatório. A coluna só existe se alguma visita
mediu — coluna inteira de "—" é ruído — e abaixo de 25mm (mesmo corte do
`avaliarRiscoColoCurto`) o valor sai em negrito.

## IP das uterinas: um gráfico por gestação, no desenho do gráfico de peso

2026-09-20. O IP médio das artérias uterinas já era plotado no relatório, mas
como *small multiple* de 220×118 (`_buildRelChartSvg('uta', …)`) — eixo, grade
e rótulos diferentes dos do peso, lado a lado com ele na mesma folha. Dois
desenhos do mesmo tipo de curva na mesma página fazem quem lê procurar
diferença onde não há. Agora é `_buildRelChartUtaSvg`: mesmo viewBox, mesmas
classes, grade com valor à esquerda, P90/P50/P10 rotulados na ponta da curva e
o percentil escrito em cima de cada ponto, igual a `_buildRelChartEfwSvg`.

- **É medida da mãe — um card por gestação, nunca por feto** (`_relCardUtaHtml`,
  alimentado por `_relPontosUterinas`). Mesma regra do colo curto e da
  pré-eclâmpsia. A linha de cada feto guarda o mesmo valor, então plotar
  `allExams` direto desenharia dois pontos sobrepostos por visita (três na
  trigemelar), e o card repetido por feto imprimiria a mesma curva materna duas
  ou três vezes. Na trigemelar ela saía uma vez por página de feto até esta
  data; passou para a página de avaliação conjunta, ao lado das outras faixas
  da gestação. Na gemelar o card não existia — agora divide a linha com a
  tabela de Doppler (`.rel-dupla`), que é onde o número dele já aparece.
- **Escala não começa no zero, ao contrário da do peso.** Lá o zero é grandeza
  real e é o que mantém os dois fetos da gemelar comparáveis; aqui a curva vive
  entre ~0,4 e ~1,8 e uma base zerada espremeria a banda P10–P90 numa tira fina
  no topo — justamente o que se lê. O passo da grade sai de uma lista de
  valores redondos (0,1 / 0,2 / 0,25 / 0,5 / 1), senão a régua imprime 0,37.
- **O eixo abre para trás quando existe medida antes de 20 semanas**, só até
  onde o primeiro ponto exige (`Math.max(11, Math.min(20, …))`), não direto
  para 11s. O rastreio de pré-eclâmpsia do primeiro trimestre mede uterinas, e
  o corte fixo em 20 semanas do `_relPatientPoints` descartava esses pontos em
  silêncio. Alargar sem necessidade espreme o trecho de 20 a 40 que se lê
  depois, por isso o eixo encosta no primeiro ponto em vez de saltar.
- **Os rótulos P90/P50/P10 têm distância mínima entre si** (10px). No peso as
  três curvas terminam bem separadas; no IP elas convergem no fim da gestação e
  os três rótulos saíam empilhados. Afasta-se o rótulo, nunca a curva.
- **O selo lê o exame mais recente com medida**, não o último exame da
  gestação: quem mediu uterinas em 24s e voltou em 32s só para biometria
  continua com o selo do valor que existe, em vez de "sem dados" sobre um
  gráfico cheio de pontos.
- **Sem nenhuma medida, o card inteiro some** — e na gemelar a tabela de
  Doppler volta a ocupar a linha toda, senão sairia espremida em meia página ao
  lado de um buraco.
- O card de peso da gestação única ganhou o subtítulo da referência (Hadlock
  1985/1991 + INTERGROWTH-21st) junto: sem ele, um card tem uma linha a menos
  que o outro e os dois gráficos começam em alturas diferentes lado a lado.

**Pendência aberta:** na tabela de Doppler da gemelar, a linha "IP artérias
uterinas (média)" ainda imprime o mesmo valor materno numa coluna por feto. O
colo já atravessa as colunas por esse motivo; as uterinas deveriam também —
mas só quando os valores das duas linhas coincidem, senão o relatório estaria
escolhendo um em silêncio.
