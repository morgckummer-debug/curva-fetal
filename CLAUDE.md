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
`obstetrico.html`, `obstetrico-1trimestre.html`, `morfologico-1trimestre.html` e
`morfologico-2trimestre.html`) grava direto em `patients`, `gestacoes` e `exams`
deste mesmo Supabase, usando o CPF como chave para achar a paciente. Toda
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
- **GPA (`gestas`/`partos`/`abortos`) vem dos quatro laudos desde 2026-09-21.**
  Antes só `obstetrico.html` e `morfologico-1trimestre.html` o gravavam: uma
  gestação criada pelo morfológico de 2º trimestre nascia com GPA nulo aqui,
  mesmo com o G/P/A impresso no laudo. Lá o campo vazio nunca apaga o que já
  está salvo, e quando os dois lados divergem o editor **pergunta** qual vale
  (modal `#cgGpaOverlay`) em vez de sobrescrever — diferente das flags de
  colo curto, que são ratchet. Consequência aqui: o GPA de uma gestação pode
  mudar entre uma visita e outra por escolha da médica no editor; não é
  sinal de dado corrompido. Ver "O GPA e os quatro laudos" no `CLAUDE.md` de
  lá.
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
percentil na Conclusão (`RCIU Precoce (< 32 semanas) (P4)`). A deterioração
Doppler (AU/DV) continua na linha seguinte — é ela que precisa ser lida junto
do diagnóstico (ver "Ducto venoso: ISUOG 2020, sem estadiamento Barcelona",
mais abaixo).

**IP das uterinas > P95 conta como critério menor também depois de 32 semanas.**
O texto estrito do Delphi 2016 só lista as uterinas no RCIU *precoce*; por causa
disso uma paciente de 38 semanas com PFE < P10 **e** IP-UtA > P95 saía como
"PIG". São dois critérios — um de tamanho e um de Doppler — e a leitura clínica
é restrição. Quem embasa é o protocolo de Barcelona (Figueras & Gratacós, Fetal
Diagn Ther 2014) — o mesmo que, até 2026-09-25, também estadiava a gravidade do
Doppler (ver seção do DV): a leitura de deterioração já contava `utAboveP95`
como o achado mais leve, ou seja, o app reconhecia o achado para dizer a
gravidade do Doppler e não para diagnosticar RCIU. Por isso a linha de
atribuição embaixo do diagnóstico (`_fonteDiagnostico`) diz "Delphi 2016 +
protocolo Barcelona" a partir de 32 semanas — creditar ao consenso um critério
que ele não tem seria errado. Essa citação de Barcelona é só sobre esse critério
menor do Delphi tardio; não tem mais nada a ver com a gravidade do Doppler
(AU/DV), que agora é ISUOG 2020/TRUFFLE — ver abaixo. Se um dia isso voltar ao
Delphi puro, é tirar `utAboveP95` de uma linha só em `calcDiagnosticoFGR` e
ajustar `_fonteDiagnostico` junto.

**Nenhum intervalo de reavaliação passa do fim da gestação.** As condutas eram
strings fixas ("Reavaliação em 4 semanas") e em 38 semanas marcavam um exame
para depois do parto. `_intervaloAteOTermo(gaW, semanas)` encurta o intervalo
para caber até 40 semanas e devolve `null` quando não cabe mais nenhum — aí o
texto passa a ser obstétrico (definir a resolução), não ultrassonográfico.
Qualquer conduta nova entra por essa mesma porta: intervalo fixo em texto puro
é o bug de 2026-09-19 voltando. (Até 2026-09-25 o RCIU também dizia um alvo de
resolução em semanas por estágio Barcelona/FIGO — isso saiu junto com o
estadiamento; ver a seção do DV.)

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
  `auDiastoleZero` e na leitura de deterioração Doppler (ver seção do DV),
  senão o achado mais grave da monocoriônica seria o único a não disparar nada.
- **Gratacós aparece ao lado do selo de deterioração Doppler (AU/DV), não no
  lugar dele** — são dois sistemas, cada um com seu nome. Até 2026-09-25 esse
  segundo selo era o estadiamento Barcelona/FIGO, removido do app inteiro (não
  só da monocoriônica) na revisão do DV — ver "Ducto venoso: ISUOG 2020, sem
  estadiamento Barcelona", mais abaixo. **Pendência aberta:** as três condutas
  por tipo de Gratacós, que são texto clínico da médica e ainda não existem —
  a conduta da monocoriônica hoje sai da mesma leitura AU/DV de qualquer
  gestação.

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

**Resolvido em 2026-09-25** (ver "Tabela de Doppler da gemelar: VR absoluto e
colo a termo", mais abaixo): a linha "IP artérias uterinas (média)" passou a
atravessar as colunas como o colo, só quando os dois fetos trazem o mesmo
valor — nunca escolhendo um em silêncio quando divergem.

## Colo curto: corte muda abaixo de 16 semanas

2026-09-21. `avaliarRiscoColoCurto` só avaliava a partir de 16 semanas — abaixo
disso, `return null` incondicional, mesmo com colo medido e claramente curto.
O corte de 25mm (Fonseca et al. 2007) é da janela clássica de rastreio de
2º trimestre; no 1º trimestre a referência da Dra. Morgana é outra: 30mm.

- **Dois cortes, dois blocos.** `gaW < 16` usa 30mm; `gaW >= 16` continua
  com 25mm e a conduta graduada de sempre (10mm/15mm, cerclagem, progesterona).
  Não é o mesmo bloco com um número trocado: a conduta graduada da faixa
  ≥16 semanas cita Fonseca 2007 e a janela de cerclagem (<24 semanas) —
  referências pensadas pra aquela idade gestacional, que não fariam sentido
  estendidas pra cá.
- **Texto simples no 1º trimestre, decisão dela.** Sem citar progesterona
  nem cerclagem — só o achado (medida, corte de 30mm) e a reavaliação na
  janela padrão de rastreio (20-24 semanas). `conduta` e `condutaRelatorio`
  saem iguais aqui: não sobra nada prescritivo pra esconder do papel, ao
  contrário da faixa ≥16 semanas onde a tela é mais completa que o relatório.
- O rótulo continua o mesmo dos dois lados: "Colo curto — Risco aumentado de
  parto prematuro" (ver decisão de nome único, 2026-09-19, acima).

## Doppler fetal (umbilical, ACM, RCP): tabelas iguais às do editor de laudos

2026-10-01. A fórmula anterior da RCP (`P50 = 1,08 + 0,006 × IG`, "Figueras")
punha a mediana em ~1,3 — muito abaixo de uma RCP normal (~1,9 em 34
semanas) — e quase todo exame normal saía P95, aqui e nos laudos. Trocada,
nos dois repositórios, por **tabelas P5/P50/P95** escolhidas pela Dra.
Morgana (`DOPPLER_FMF` no `index.html`; no `laudo-core.js` do
`laudos-dramorgana` é a mesma):

- IP da umbilical: Acharya 2005 (AJOG 192(3):937-944), 19–40 semanas;
- IP da ACM: Ciobanu/FMF 2019 (UOG 53(4):465-472), 20–41 semanas;
- **RCP: Baschat & Gembruch 2003 (UOG 21:124-127), por equações**, 20–42
  semanas: média = −0,0059×IG² + 0,383×IG − 4,0636 e DP = −0,00113×IG² +
  0,07156×IG − 0,67418 (versão corrigida do DP). É o que o Fetalmed e a
  Cetrus usam — o mesmo exame dava P61 pelo Ciobanu e P48 neles.

`dopplerAuRef`/`dopplerAcmRef`/`dopplerCprRef` seguem devolvendo
`{p10,p50,p90}` (agora com o P5 e o P95 de verdade nessas chaves, que é como
os cortes "≤P5"/"≥P95" e os gráficos já as liam) e `calcDoppler*` e o z-score
de `_z.au/acm/cpr` usam a normal "dividida" (DP inferior = (P50−P5)/1,645,
superior = (P95−P50)/1,645). Fora da faixa da tabela devolvem `null`.
**Mudou uma tabela aqui, mude no `laudo-core.js` — e vice-versa.**

## PIG vs CIUR: o laudo passou a aplicar os mesmos critérios menores

2026-09-21, mesma conversa. Confirmado pela médica: "o app está correto" — o
laudo obstétrico (`obstetrico.html`, 2º/3º trimestre) decidia PIG vs CIUR só
pelo percentil do exame do dia (≤P3 = CIUR, 5-10 = PIG), sem olhar Doppler.
Um feto em P8 com IP-uterinas>P95 saía "PIG" no laudo e "CIUR" no relatório
evolutivo daqui — mesma paciente, dois papéis discordando no mesmo dia.

O editor passou a portar `calcDiagnosticoFGR` (só a parte que um exame único
consegue calcular, sem histórico): em gestação única, um feto em percentil
5-10 fecha CIUR se, antes de 32 semanas, IP-umbilical>P95 ou IP-uterinas>P95;
a partir de 32 semanas, se fechar 2 dos 3 critérios menores (RCP<P5 ou
IP-umbilical>P95 ou IP-uterinas>P95 contam como um critério só; ACM<P5 conta
como um segundo, independente — mesmo invariante daqui: o percentil ≤10 já é
sempre o critério de crescimento que falta). Para isso o editor ganhou os
percentis de IP-umbilical (Acharya 2005) e IP-ACM (Ebbing 2007), que antes só
existiam aqui — mesmas fórmulas, funções próprias (`calcAuPercentil`/
`calcAcmPercentil`), sem campo novo na tela (o laudo continua imprimindo o IP
bruto e a classificação normal/alterada que a médica já escolhia).

**Só em gestação única** — mesma regra desta app (ver "Gemelar não é gestação
única duas vezes", acima): numa gemelar/trigemelar o editor continua com o
corte fixo em percentil (o CIUR seletivo da múltipla ele ainda não calcula).

**Pendência que ficou aberta no editor**: falta o critério isolado de diástole
zero/reversa da umbilical (AEDF/REDF), que aqui fecha RCIU precoce sozinho —
o editor só tem o IP numérico da umbilical, sem campo pra classificar o fluxo
diastólico. Se esse campo for criado lá, ele precisa entrar nessa regra
também. Mudar os critérios aqui sem espelhar lá volta a abrir a divergência.

## TAPS e a curva de PSV-ACM de monocoriônicos

2026-09-24. A app calculava o MoM do PSV-ACM com a curva de feto único para
todo mundo e não tinha nada de TAPS — a sequência anemia-policitemia, que é
uma complicação exclusiva de monocoriônica.

- **Duas curvas, escolhidas pela corionicidade.** `_PSV_MEDIANA_MCDA`
  (Klaritsch et al., UOG 2009, Tabela 3 — 50 gestações MCDA, 824 medidas,
  15 a 37 semanas) entra por `calcPsvMom(psv, gaW, gestacao)` sempre que
  `_ehMonocorionica`. Fora de 15–37 não há o que extrapolar e a de feto único
  volta a valer. O motivo é a faixa precoce: antes de 18 semanas o PSV é bem
  mais alto no monocoriônico (+26% em 15 semanas, +16% em 16, +8% em 17), e
  dividir por uma mediana baixa demais inventa anemia onde não há. De 18 a 37
  o próprio artigo diz que as curvas são equivalentes.
- **`calcPsvMom` devolve `curva`**, e o texto do Doppler imprime "Klaritsch"
  quando não é a curva de sempre. Mesma regra do `_fonteDiagnostico`: quem lê
  um MoM tem de poder saber de que mediana ele saiu.
- **TAPS é achado da gestação** (`avaliarTAPS`), como o colo e as uterinas.
  Não cabe dentro do `computeImpressaoDiagnostica` de um feto porque nasce da
  diferença entre os dois — e por isso, na Conclusão, ela chega como terceiro
  argumento do `_gerarConclusaoGemelarInicial` em vez de sair de um
  `.find(Boolean)` sobre os fetos, que é como o colo e a pré-eclâmpsia chegam.
- **Só monocoriônica com dois fetos.** Os dois sistemas de estadiamento foram
  definidos para gemelar monocoriônico; numa trigemelar não existe "o par", e
  escolher dois dos três seria invenção nossa.
- **Compara a visita mais recente em que OS DOIS têm PSV medido.** O PSV de
  hoje de um feto contra o da semana passada do outro não é delta de MoM, é
  ruído de duas idades gestacionais. Sem visita pareada, `null`.
- **Dois sistemas lado a lado**: Leiden (Slaghekke 2010) pelos MoM absolutos
  dos dois fetos, critérios de 2019 (Tollenaar) pelo delta entre eles.
  Prevalece o mais alto, e quando divergem o subtítulo diz isso — a
  sensibilidade antenatal maior do delta é justamente o que motivou a proposta
  de 2019, e esconder o desacordo seria escolher um em silêncio.
- **Estadiamento vai até 3.** O estágio 3 sai de `au_fluxo`/`dv_onda` do
  doador, que a app registra. Hidropsia (4) e óbito (5) não têm campo aqui —
  o texto diz isso em vez de deixar entender que foram descartados. Mesmo
  motivo pelo qual a app avisa que Gratacós não é calculado.
- **TAPS ≠ STFF.** A TAPS se define pela discordância de hemoglobina *sem*
  sequência oligo-polidrâmnio. A app não registra bolsão dos dois fetos de
  forma a fechar esse critério, então o texto avisa em vez de afirmar que não
  é STFF.

**Pendência aberta e importante: `_PSV_MEDIANA` não parece ser Mari 2000.**
A tabela bate com a fórmula publicada de Mari (`e^(2,31 + 0,04643 × IG)`) até
20 semanas e depois descola progressivamente: +9,8% em 28 semanas, +29% em 34,
+57,7% em 40. Os dados do Klaritsch, que são medida independente e que o
artigo descreve como sobreponíveis às de feto único entre 18 e 37 semanas,
acompanham a fórmula e não esta tabela (-33% contra ela em 37 semanas). Como a
mediana está no denominador, um valor inflado **subestima o MoM** — o erro cai
para o lado de não ver anemia. Um feto de 36 semanas com PSV de 80 cm/s sai
daqui como 1,08 MoM ("dentro do esperado") e pela fórmula seria 1,49 MoM, na
borda do corte de anemia moderada/grave. A aba de Anemia Fetal do
`morgckummer-debug/CalcMK` usa a fórmula e portanto **discorda desta app sobre
a mesma paciente** — a mesma classe de divergência do RCP e do PIG × CIUR.
Não foi alterado aqui porque muda o comportamento de anemia de toda gestação
única da app e a decisão é da médica. Se for corrigido, a tabela do Klaritsch
não muda: ela é dado publicado, independente desta.

## Ducto venoso: ISUOG 2020, sem estadiamento Barcelona

2026-09-25, a pedido da médica: trocar a referência do DV de uma aproximação
própria para uma tabela publicada, e trocar a leitura de gravidade do
estadiamento Barcelona/FIGO (Figueras & Gratacós 2014) para a leitura de
deterioração Doppler que a ISUOG 2020 (Lees CC, Stampalija T, Baschat A, et
al. *ISUOG Practice Guidelines: diagnosis and management of small-for-
gestational-age fetus and fetal growth restriction.* Ultrasound Obstet
Gynecol 2020;56:298-312) adota via protocolo TRUFFLE.

- **`_dvP95(gaW)` não é mais aproximação.** Até aqui era uma reta própria do
  app, comentada "Baschat/FMF" mas sem tabela publicada por trás. Virou
  lookup em `_DV_P95_KESSLER`, a Tabela 3 de Kessler J, Rasmussen S, Hanson M,
  Kiserud T. *Longitudinal reference ranges for ductus venosus flow
  velocities and waveform indices.* Ultrasound Obstet Gynecol 2006;28:890-898
  (547 medidas, 160 gestações de baixo risco) — a médica enviou a tabela
  impressa. Cobre 24–39 semanas; a semana 32 não está na tabela publicada e
  foi interpolada linearmente entre 31 (0,79) e 33 (0,77). Fora de 24–39
  semanas não há dado publicado — em vez de extrapolar, `_dvP95` mantém o
  valor da borda mais próxima (mesmo espírito conservador do clamp anterior).
  As três chamadas (estadiamento, gráfico do DV, resumo em tela) continuam
  únicas — não há cutoff duplicado em nenhum outro lugar.
- **Onda A ausente e reversa viraram o mesmo patamar de gravidade.** A ISUOG
  2020/TRUFFLE separa só dois achados do DV: *precoce* (IP > P95 com onda A
  ainda presente) e *tardia* (onda A ausente, na linha de base ou reversa —
  tratadas como uma coisa só). Até aqui o app fazia uma escada de três: onda A
  ausente contava como restrição moderada e nem entrava no estadiamento;
  reversa era a única coisa que fechava o estágio mais grave. Isso mudou em
  todo lugar que olhava para `dv_onda` com peso diferente para os dois
  valores: estadiamento (agora deterioração Doppler, ver abaixo), status
  fisiológico (`RESTRICAO_GRAVE` para as duas), cor do gráfico (mesmo tom
  escuro), selo do card (mesma classe de alerta) e `_dopplerAlteradoNoExame`
  (conta as duas para a leitura de PIG constitucional). O dropdown de Onda A
  continua com três opções (positiva/ausente/reversa) — "na linha de base" não
  ganhou um valor próprio porque é a mesma leitura de "ausente" na
  terminologia da ISUOG, não um terceiro estado clínico.
- **O estadiamento Barcelona/FIGO (Estágio I–IV) saiu do app inteiro**, não só
  do DV — a médica pediu para tirar a classificação, não só trocar a fonte do
  corte de IP. `calcDiagnosticoFGR` não devolve mais `estadio` (1–4); devolve
  `deterioracaoDoppler`, uma de quatro strings (`'leve'|'aedf'|'redf_dv'|
  'dv_tardio'`, ou `null` quando não há RCIU ou não há Doppler suficiente),
  com rótulo e cor em `_DETERIORACAO_CFG` — uma implementação só, reaproveitada
  pelo Resumo em tela e por `computeImpressaoDiagnostica` (as duas cópias
  literais do dicionário de estágio que existiam antes tinham exatamente a
  mesma forma). Não há mais numeração romana em lugar nenhum do app.
- **Junto saiu o "alvo de resolução" por estágio** (37/34/30/26 semanas,
  `_ALVO_RESOLUCAO`/`_ROMANO_ESTADIO`, removidos). Não foi só uma re-citação:
  a médica decidiu não afirmar mais uma IG-alvo de parto vinda de uma tabela
  de estágios — `_condutaDiagnostico` agora só descreve o achado (AEDF, REDF/
  DV-precoce, DV-tardio) e a cadência de Doppler correspondente, e quando
  resolver a gestação fica explicitamente com o obstetra, mesma régua já
  usada para o colo curto (ver seção própria). Os intervalos de vigilância que
  restam continuam cortados por `_intervaloAteOTermo`.
- **O que NÃO mudou:** o critério de IP-UtA > P95 como critério menor do RCIU
  tardio (Delphi + protocolo Barcelona, `_fonteDiagnostico`) é uma decisão de
  *diagnóstico*, não de estadiamento — continua citando Figueras & Gratacós
  2014, porque é dali que esse critério específico vem. A classificação de
  Gratacós (Tipo I–III, CIUR seletivo em monocoriônica) e o estadiamento
  Leiden/Tollenaar da TAPS também não mudaram — são sistemas próprios, sem
  relação com o Barcelona/FIGO que saiu.
- Se um dia a ISUOG 2020 tiver cortes de IG-alvo de parto por achado que a
  médica queira adotar (o texto integral da diretriz não foi acessível para
  conferir os números exatos — só a tabela do DV foi confirmada, enviada por
  ela), isso entra como uma nova decisão explícita, não como uma
  reintrodução silenciosa do `_ALVO_RESOLUCAO` antigo.

## Tabela de Doppler da gemelar: VR absoluto e colo a termo

2026-09-25, a partir de uma página real do PDF que a médica trouxe.
`_buildRelDopplerGemelarHtml` monta a tabela de Dopplervelocimetria + colo do
relatório gemelar/trigemelar. Duas mudanças, mais a pendência das uterinas que
já estava aberta.

- **A coluna "Referência" mostra o corte de verdade, não só "&lt; P95"/"&gt;
  P5".** "VR 1,05" não diz nada a quem lê sem abrir uma tabela de percentis;
  "VR &lt; 1,05" diz exatamente onde está o limite, na IG daquela visita. O
  número **não é um corte novo** — é o mesmo que `calcDopplerUt/Au/Acm/Cpr` já
  usava para decidir se a célula pinta de vermelho (`class="fora"`), só que
  antes ficava escondido dentro da fórmula: `dopplerAuRef(gaW).p90` é
  exatamente o valor em que `calcDopplerAu` já virava percentil 95, e o mesmo
  vale para `dopplerAcmRef(...).p10`/`dopplerCprRef(...).p10` (percentil 5) e
  para `exp(mu + 1.645·sd)` do modelo log-normal do UtA (Gómez 2008). Escrever
  um corte diferente do que já pinta a célula criaria uma tabela que discorda
  dela mesma — um "VR 1,05" ao lado de um valor "fora da faixa" que na
  verdade é menor que 1,05.
- **IP das uterinas virou uma linha só, atravessando as colunas — a pendência
  que já estava documentada aqui.** É medida materna, igual ao colo logo
  abaixo; as duas colunas por feto vinham do mesmo valor duplicado na leitura
  de cada um. Só faz o colspan quando os dois fetos concordam
  (`utDivergente`); se divergirem, a tabela volta a mostrar uma coluna por
  feto em vez de escolher um valor em silêncio — a mesma cautela que a
  pendência original pedia.
- **Colo a termo (≥ 37 semanas) não leva VR nem marcação de "fora da
  faixa".** O corte de 25mm existe para prever parto antes de 37 semanas
  (Fonseca et al. 2007); a partir de 37 semanas esse desfecho já não pode
  mais acontecer, então aplicar o mesmo corte imprimiria uma predição para um
  evento que passou. A linha continua existindo — a medida do ultrassom é
  registro, sempre vale a pena mostrar — só que sem comparação nenhuma ao
  lado. Mesmo espírito do "relatório não prescreve" do colo curto (ver seção
  própria): um número sem corte não sugere conduta nenhuma, só documenta o
  achado. `avaliarRiscoColoCurto` — a função que decide o texto de risco na
  Conclusão, nos alertas e no card por feto — ganhou o mesmo corte no mesmo
  dia, confirmado pela médica: `gaW >= 37` devolve `null` antes de qualquer
  outro corte (16 semanas, 25mm etc.). `null` aqui é "não se aplica mais", não
  "colo normal" — a medida continua na coluna Colo do histórico
  (`_relColoCel`, que não tem corte de IG e não mudou) e na tabela de Doppler,
  só sem avaliação de risco. Telas e papel voltam a concordar: nenhum lugar do
  app afirma risco de parto prematuro depois de 37 semanas.

## AEDF/REDF/iAREDF: sigla fora do relatório, decisão da médica

2026-09-25. Obstetra não reconhece as siglas AEDF/REDF/iAREDF (Absent/Reversed/
intermittent Absent-or-Reversed End-Diastolic Flow) — só a ultrassonografista
usa esse vocabulário. Todo texto que chega ao relatório/PDF ou é compartilhado
entre tela e papel (`_DETERIORACAO_CFG`, `_critItemsDiagnostico`,
`_condutaDiagnostico`, `_GRATACOS_CFG`) passou a descrever o achado por
extenso — "Diástole ausente em artéria umbilical", "Diástole reversa em
artéria umbilical", "Diástole intermitentemente ausente ou reversa na artéria
umbilical" — sem a sigla entre parênteses.

**O dropdown de Onda A da AU e o `interpAU` do Resumo em tela (`_buildSummaryHtml`)
mantiveram a sigla de propósito.** São ferramentas de trabalho da própria
médica, não texto que sai da clínica — ela conhece o vocabulário, e a sigla é
mais rápida de ler numa tela que ela usa o dia inteiro. A régua é a mesma do
"relatório não prescreve" do colo curto: o que muda de público muda de
linguagem.

De caminho, corrigi um resíduo da remoção do estadiamento Barcelona
(2026-09-25, ver seção do DV): o `interpAU` do Resumo em tela ainda dizia
"critério estadiamento III"/"critério estadiamento II" para REDF/AEDF na AU —
um sistema que não existe mais no app. Agora diz "mesmo patamar de gravidade
do DV com IP > P95 (ISUOG 2020)" e "achado de deterioração Doppler".

## CIUR seletivo cobre todo o espectro de restrição na múltipla, não só o leve

2026-09-25, a partir de uma Conclusão real que a médica trouxe: um feto de
gemelar com PFE no P11 saía "Feto RCIU precoce" — a sigla de gestação única
que "Gemelar não é gestação única duas vezes" (2026-09-20, ver acima) dizia
ter corrigido, só que a correção só cobria `pig`.

`_DX_NOME_MULTIPLA` tinha só `{ pig: 'CIUR seletivo' }`. `rciu_precoce` e
`rciu_tardio` nunca entraram ali — por isso o card do feto, o Resumo e a
Conclusão continuavam dizendo "RCIU precoce"/"RCIU tardio" pra um feto de
gemelar com restrição mais grave, exatamente o erro que a seção de 2026-09-20
já tinha corrigido, só que pela metade. Agora as três chaves apontam pra "CIUR
seletivo": todo grau de restrição na múltipla tem o mesmo nome, do que a régua
de única chamaria PIG ao que chamaria RCIU tardio — o que muda com a
gravidade é a conduta e a deterioração Doppler, nunca o nome (mesmo princípio
já valia pro PIG, ver acima).

Duas cópias precisaram do mesmo ajuste, porque bypassavam `_dxNome`:
- `_fonteDiagnostico` só testava `diagnostico === 'pig'` pra atribuir "CIUR
  seletivo · critérios de gestação única aplicados por feto" em vez de
  "Delphi 2016 + Barcelona" — um feto de gemelar com RCIU tardio continuava
  creditado à régua de única.
- O `DX_ROTULO` local de `_gerarConclusaoGemelarInicial` tinha `rciu_precoce`/
  `rciu_tardio` como `['Feto RCIU precoce', ...]`/`['Feto RCIU tardio', ...]`
  hardcoded, nunca passando por `_dxNome`/`_DX_NOME_MULTIPLA` — era essa cópia
  que gerava a linha "Feto RCIU precoce" da Conclusão do exemplo.

**O que NÃO muda:** o diagnóstico interno continua `'pig'`/`'rciu_precoce'`/
`'rciu_tardio'` — só o nome exibido. A conduta, as notas e a deterioração
Doppler de cada feto continuam vindo do valor interno real, não do rótulo.

## Conduta sugerida na múltipla: uma só, a do feto de pior prognóstico

Mesma conversa, 2026-09-25. Até aqui, quando os fetos de uma gemelar tinham
condutas diferentes, a Conclusão listava as duas: "Conduta sugerida (Feto 1):
..." e "Conduta sugerida (Feto 2): ...". A médica apontou que isso não faz
sentido clínico — é uma mãe só, uma agenda de retorno só, uma decisão de
internação só. A conduta do feto sem achado não acrescenta nada quando o
irmão já dita o plano; não precisa nem aparecer.

`_gerarConclusaoGemelarInicial` agora escolhe **o pior feto entre os que têm
CIUR** (`pig`/`rciu_precoce`/`rciu_tardio` — todos "CIUR seletivo" agora, ver
acima) e imprime só a conduta dele, sem citar o outro feto:

- **Critério de desempate, definido pela médica:** primeiro a deterioração
  Doppler (`_DETERIORACAO_ORDEM`: DV tardio > REDF/DV precoce > AEDF > achado
  leve > nenhuma) — ela já enxerga o ducto venoso, que pesa mais que a
  umbilical isolada sozinha. Só **dentro do mesmo patamar** o IP da artéria
  umbilical decide (maior = pior). Comparação direta, sem precisar de
  percentil: os dois fetos são examinados na mesma visita, mesma IG.
- **Sem nenhum feto com CIUR** (ex.: um GIG e um adequado), a Conclusão volta
  ao comportamento anterior — junta quando a conduta é igual, lista por feto
  quando diverge — porque não existe uma hierarquia de gravidade definida
  entre esses dois diagnósticos como existe dentro do espectro de restrição.
- O card de cada feto (`feto-card-conduta`) **não muda**: continua mostrando a
  conduta individual daquele feto. A escolha do pior vale só pra linha
  "Conduta sugerida" da Conclusão, que é o resumo executivo.
- `computeImpressaoDiagnostica` ganhou o campo `deterioracaoDoppler` (a chave
  crua, `'leve'|'aedf'|'redf_dv'|'dv_tardio'|null`) ao lado de `estadio` (que
  já era o objeto `{label,cor}` pra exibir) — só pra esta comparação entre
  fetos precisar de algo comparável, sem reverter o rótulo de exibição.

## Conclusão volta a mostrar o critério — só o percentil não justifica o rótulo

Mesma conversa, 2026-09-25. A médica leu uma Conclusão real e apontou: "Feto 2
no percentil 11 — Feto RCIU precoce" não diz **por quê** — um leitor sem
acesso ao card do feto não tem como saber se foi o percentil, o Doppler, ou os
dois. Isso desfaz parte de uma decisão de 2026-09-20 ("Conclusão do relatório:
formato definido pela médica", acima), que tinha tirado o critério da
Conclusão por ser "informação a mais que tirava o foco" — a médica decidiu que
precisão clínica pesa mais aqui, e confirmou: a lista inteira de
`_critItemsDiagnostico`, sem filtrar o item biométrico que repete o percentil
("CA e/ou PFE abaixo do P10" ao lado de "no percentil 11" — redundante, mas a
escolha foi não cortar nada).

- **Única** (`_gerarConclusaoUnicaInicial`): `critItems` entra na primeira
  linha, logo depois do percentil — `"RCIU Precoce (P4) + Diástole ausente na
  artéria umbilical."`. A linha própria de `estadio` (a deterioração Doppler
  resumida) saiu daqui: ela virou redundante, porque o achado que ela citava
  já está dentro de `critItems` agora.
- **Múltipla** (`_gerarConclusaoGemelarInicial`): mesma ideia, encaixada antes
  do travessão do rótulo — `"Feto 2 no percentil 11 + Diástole ausente na
  artéria umbilical — critérios de CIUR seletivo."`. Complicador que a única
  não tem: um grupo pode juntar **mais de um feto** com o mesmo diagnóstico
  (ex.: os dois "CIUR seletivo"), e os critérios de cada um podem ser
  diferentes. Só combina numa linha quando os critérios batem entre todos os
  fetos do grupo; se divergirem, uma linha por feto — a mesma cautela de
  "nunca escolher em silêncio" que já regia o colspan das uterinas e o
  desempate de conduta, acima.
- **O que NÃO muda:** o card de cada feto (`_gerarTextoCardFetoInicial`) já
  mostrava `critItems[0]` (só o primeiro) e a faixa de status em tela
  (`_renderStatusFaixaHtml`) já mostrava `estadio.label` — nenhum dos dois foi
  tocado. Só a Conclusão, que era o único lugar sem nenhum critério.

## Página da gemelar: `.rel-dupla` 40/60, e a conduta saiu do card do feto

2026-09-25, mesma revisão de layout. Dois ajustes na página de uma folha só da
gemelar (`_buildRelGemelarPaginaHtml`).

- **`.rel-dupla` (o grid que divide a linha entre o card das uterinas e a
  tabela de Doppler+colo) era 1fr 1fr, e a tabela quebrava linha demais** —
  ela tem `Parâmetro` + uma coluna por feto + `Referência`, contra um card que
  é só um gráfico. Virou `2fr 3fr` (40/60), nas três cópias da regra (preview
  em tela e CSS exportado — ver `_buildRelDopplerGemelarHtml` para o que essa
  tabela mostra desde o VR absoluto).
- **A conduta sumiu de baixo do gráfico de cada feto** (`feto-card-conduta`,
  classe e HTML removidos dos dois lados — preview e exportado). Fazia
  sentido enquanto cada feto tinha sua própria conduta impressa; desde a seção
  anterior ("Conduta sugerida na múltipla: uma só..."), a Conclusão já mostra
  uma conduta só, a do pior feto — repetir a conduta individual de cada um
  embaixo do card virou dois planos escritos lado a lado, um dos quais nem é
  mais o que vale. A conduta continua central: só mudou de lugar, da margem
  de cada card para a Conclusão, que é onde ela já é decidida.

## 1º trimestre — gráficos e riscos FMF, e o corte que virou 15 semanas

2026-09-27. A médica relatou dois problemas na aba "Gráficos": um feto de 13
semanas abria a aba e via os 9 cards de biometria/peso/Doppler de 2º/3º
trimestre com a curva de referência desenhada e nenhum ponto — gráfico que
"não tem nada a ver" com um feto tão pequeno — e, de um modo geral, nenhum
gráfico plotava ponto antes de ~20-21 semanas. Junto, ela já tinha montado no
editor de laudos (`laudos-dramorgana/morfologico-1trimestre.html`) uma página
de referência da FMF (8 gráficos + campos de risco T21/T18/T13/pré-eclâmpsia)
e queria isso replicado aqui, com layout próprio.

### O corte de 20 semanas era maior do que a própria tabela de referência

`buildChart()`, `buildEFWChart()` e `_relPatientPoints()` (PDF) recusavam
qualquer exame com `igDays < 140` (20 semanas) — comentado como intencional,
em três lugares independentes. Mas `REF_TABLES` (CA/CC/fêmur/DBP, Hadlock
1984) já tem entradas a partir da **semana 14**, e `TABELA_PESO_HADLOCK`
(EFW) começa na semana **10** — o corte de tela não vinha de falta de dado,
era só mais conservador do que a própria referência que ele usa.

Confirmado com a médica: os 8 gráficos do editor (FC/CCN/TN/DBP-precoce/DV/PI
uterina E,D,média) cobrem 11-14 semanas com referências próprias, **não** é
pra calcular peso por Hadlock nessa janela, e o corte dos gráficos padrão
(biometria/EFW) devia virar **15 semanas** (105 dias), não mais 20 — nem 14.
Mudou nos três lugares (mais os domínios de eixo hardcoded em `_buildRelChartSvg`/
`_buildRelChartEfwSvg`, que iam de 20 a 40 semanas e agora vão de 15 a 40 —
sem isso um ponto de 15-19 semanas simplesmente cairia fora do viewBox do
relatório). Os gráficos de Doppler AU/ACM/CPR/DV **continuam em 20 semanas**
— não há referência publicada nem prática clínica padrão pra eles antes
disso, e o achado precoce (ducto venoso) entra pela seção nova, com
referência própria (Pruksanusak 2014), não estendendo a curva de 2º/3º
trimestre pra trás.

### Bloco novo, não substituição: `#charts-1tri`

Os 8 gráficos do editor foram portados **linha a linha** (mesma tabela, mesma
citação de fonte) pra dentro de `index.html` — `crlFromGAdays_hyett`,
`HADLOCK_CCN_GA_DAYS`/`crlFromGAdays_hadlock`, `TN_TABLE`/`linRegress`/
`TN_P5_REG`/`TN_P50_REG`/`TN_P95_REG`, `DBP_TABLE_WEEKS`, `DV_TABLE`,
`interpTabelaRef` — logo depois de `ccnToIgStr()`. As 3 uterinas (E/D/média)
**não** duplicam fórmula: reaproveitam `_utGomezParams`/`dopplerUtRef`, que já
cobre 11-41 semanas, chamando `buildDopplerChart()` três vezes (uma por
lado/média) em vez de escrever um desenho novo.

Os 5 gráficos restantes (`buildChart1TriFC`, `buildChart1TriCcn`,
`buildChart1TriTN`, `buildChart1TriDbp`, `buildChart1TriDV`) usam o **mesmo**
motor Canvas da aba (`_drawChart`) — não o SVG desenhado à mão do editor
(`buildGraficoCard`/`renderGraficoCardHtml`). Só ter um sistema de gráfico na
mesma tela era mais importante do que economizar a portagem do motor SVG.
Isso exigiu dois parâmetros novos em `_drawChart`, os dois opcionais e com
default igual ao comportamento antigo — `xStep` (espaçamento da grade
vertical, default 2, pequeno demais pros cards com eixo em CCN/mm) e `xFmt`
(formata o rótulo do eixo X, default `x+'s'` assumindo semanas — os cards de
TN/DV, com eixo em mm, passam o próprio).

`_pointsForFeto1Tri(gestacao, exams, extractor)` filtra os 5 gráficos
"estreitos" pra janela 10-15 semanas (a mesma do editor); as uterinas ficam
de fora desse filtro de propósito — mostram a gestação inteira, é o mesmo
comportamento do card "IP Médio — Artérias Uterinas" que já existe no grid
padrão, só que em 3 cards em vez de 1.

**O bloco não substitui o grid padrão — os dois convivem, cada um só quando
há dado pra ele:**

```
renderCharts(gestacao, exams, allExams):
  mostrar1Tri = existe exame com IG entre 10 e 15 semanas   → #charts-1tri
  mostrarGrid = existe exame com IG ≥ 15 semanas            → #charts-grid-padrao
```

`_temExame1Tri`/`_temExameDesde15Sem` decidem isso a partir do dado que
existe, não de corionicidade/feto — é o que resolve o bug relatado: uma
gestação só com exame de 11-14 semanas não tem `mostrarGrid`, então o grid de
biometria/peso/Doppler de 2º/3º trimestre nem aparece (em vez de aparecer
vazio); assim que existir um exame ≥15 semanas, ele volta, ao lado do bloco
de 1º trimestre — histórico completo, nada escondido.

**Cuidado ao mexer no grid padrão: ele ganhou um id.** `document.querySelector
('#tab-charts .charts-grid')` (usado por `renderCharts`/`applyChartsScope`)
parava de funcionar assim que existisse um segundo `.charts-grid` na mesma
aba — o `#charts-1tri` reaproveita essa classe pro layout de grade, e
`querySelector` pega o primeiro que aparece no DOM (o de 1º trimestre, que
vem antes). Os dois lugares que liam por classe passaram a ler por
`document.getElementById('charts-grid-padrao')`, o id do grid de sempre.

**O seletor Feto 1/2/Gestação (`renderChartsFetoToggle`) é chamado sempre**,
antes de decidir qual bloco aparece — os 5 gráficos "estreitos" também são
por feto (FC, CCN, TN, DBP, DV), então gemelar/trigemelar precisa dele mesmo
quando só o bloco de 1º trimestre está visível. `applyChartsScope()` chama de
novo mais abaixo (idempotente, harmless) — não valeu a pena tirar a chamada
de lá só por isso.

### Riscos T21/T18/T13/pré-eclâmpsia — Fase 1: digitados aqui, não sincronizados do editor

Mesma decisão do editor de laudos: **não são calculados**, são digitados a
partir do resultado do software oficial da FMF. Seis colunas novas em
`exams` (migração `012_campos_1_trimestre.sql`): `nt`, `fc` (marcadores, por
feto — mesmo tratamento de `ccn`/`dbp` no rascunho por feto,
`_ME_FETO_FIELD_IDS`), `risco_t21`/`risco_t18`/`risco_t13` (por feto, texto
livre "1 em X") e `risco_pre_eclampsia` (achado **materno** da visita, lido
sempre do formulário na tela via `sharedStr`, nunca do rascunho de outro
feto — mesmo padrão de `colo`/`aut_e`/`aut_d`).

**Decisão explícita de escopo, confirmada com a médica, à época**: por
enquanto era só aqui — o editor de laudos continuava sem gravar esses campos
no Supabase. O loop fechado (editor grava, Curvas só lê) ficou pendente até
ela pedir — o pedido veio em 2026-09-27 e fechou essa lacuna (ver "Loop
fechado: o morfológico de 1º trimestre também grava estes campos", logo
abaixo). Até lá, quem quisesse ver o risco no Curvas tinha que digitar aqui
também, sem sincronizar com o laudo impresso — essa frase descreve o estado
antes da mudança, não o atual.

`renderRiscoFmfCards()` replica a regra de monocoriônica do editor (ver
`CLAUDE.md` de lá, "Monocoriônica: um cálculo de risco só") — reaproveitando
`_ehMonocorionica()`, que já existia aqui pro TAPS: quando a gestação é
monocoriônica, sai **um cartão só**, com os valores do feto A, rotulado
"Ambos os fetos"/"Os três fetos" (nunca um cartão por feto — o rastreamento
combinado dá um risco só pra gestação inteira). Dicoriônica/triamniótica
continua um cartão por feto. Pré-eclâmpsia é sempre um cartão à parte,
independente do número de fetos — é achado da mãe.

### Visual — sem identidade própria, de propósito

Até 2026-09-28 `.charts-1tri`/`.risco-fmf-card` usavam um azul (`#1a56b0`,
o tom que o editor de laudos usa pra imitar o relatório oficial da FMF).
Revertido a pedido da médica, depois de ela ver o preview do relatório
evolutivo pela primeira vez: o acompanhamento começa no morfológico de 1º
trimestre, é a mesma gestação, o mesmo documento evoluindo até o final — não
um produto colado com marca própria. Hoje `.charts-1tri-title`/
`.risco-fmf-card-t` usam `var(--sage-deep)`, `.risco-fmf-card` usa
`var(--sage)` no `border-top`, e o `.chart-card--1tri::before` (que
recolorava o degradê do topo do card) foi removido — os 8 cards da tela
voltam a usar o mesmo `::before` sálvia/pêssego de qualquer outro
`.chart-card`. `.risco-fmf-card--pe` (pré-eclâmpsia) continua com
`--peach-warm`, que já era paleta do app.

## Loop fechado: o morfológico de 1º trimestre também grava estes campos

2026-09-27. A seção anterior deixava documentado que TN/FC/T21/T18/T13/
pré-eclâmpsia/parto prematuro/diabetes gestacional eram "Fase 1" — só
digitados aqui, com o editor de laudos (`laudos-dramorgana`,
`morfologico-1trimestre.html`) sem gravar nada disso no Supabase, mesmo já
tendo os mesmos campos no próprio formulário dele (é de lá que a página de
referência FMF foi portada, ver "1º trimestre — gráficos e riscos FMF",
acima). A médica pediu para fechar esse loop: agora o botão "Salvar na Curva
de Crescimento" desse laudo também manda esses oito campos.

**Nada mudou deste lado.** As colunas já existiam (migrações 012/013), a
tela já lia e exibia tudo (`_EXAM_COLUMNS`, `renderRiscoFmfCards`,
`_achadoRiscoPreEclampsia1Tri` e as duas irmãs) — o Curvas nunca soube (nem
precisa saber) se o valor de um exame veio de alguém digitando aqui ou do
insert do editor. Só o `morfologico-1trimestre.html`, no bloco `// ----
Integração com a Curva de Crescimento (Supabase) ----`, ganhou os campos
novos no `exames.map()` que já monta um `exams` por feto:

- **`nt`/`fc`: por feto, sempre.** São medida física do feto (TN em mm,
  frequência cardíaca em bpm) — não tem variante "materna" nem precisa de
  tratamento especial em monocoriônica, mesmo grupo de `ccn`/`dbp` que o
  laudo já mandava.
- **`risco_t21`/`risco_t18`/`risco_t13`: por feto, sem replicar em
  monocoriônica.** O formulário do editor só mostra (e só deixa preencher)
  o cartão de risco do 1º feto quando a gestação é monocoriônica
  (`feto{uid}RiscoWrap` escondido para os demais, ver `CLAUDE.md` de lá,
  "Monocoriônica: um cálculo de risco só") — então o 2º/3º feto chegam aqui
  com esses três campos vazios/null por construção. Não é bug nem precisa de
  correção: `_riscoFmfCardsHtml`/`_ehMonocorionica`, deste lado, já filtram
  só os exames do feto A nesse caso (`allExams.filter(e => e.feto ===
  fetos[0])`) — os dois lados concordam em qual feto carrega o cálculo
  combinado sem precisar duplicar o valor.
- **`risco_pre_eclampsia`/`risco_parto_prematuro`/`risco_diabetes_gestacional`:
  achado materno, replicado em todos os fetos** — mesmo padrão de `aut_e`/
  `aut_d`/`colo`, que já iam repetidos numa gemelar. Pré-eclâmpsia só entra
  se o cartão "Rastreamento de pré-eclâmpsia (FMF)" estiver marcado no
  editor (`chkPreEclampsia`); os outros dois entram sempre que o campo do
  denominador ("1 para X") estiver preenchido na última página do laudo.
- **Formato: só o denominador chega no editor** (ela digita "1200", não
  "1 em 1200" — os campos de lá pedem só o número, que a impressão do
  próprio laudo já mostra como "1: 1200"). Uma função local, `riscoTxt`,
  prefixa `'1 em '` antes de gravar — para bater com o texto livre que o
  Curvas já espera (mesmo placeholder "1 em X" dos seis campos aqui) e com
  o que entra direto nas frases da Conclusão (`Rastreamento combinado do 1º
  trimestre: risco de ${valor} para...`).

**O que fica de fora, de propósito:** o editor não manda `nt`/`fc`/os seis
riscos para nenhum outro laudo (`obstetrico-1trimestre.html` não tem esses
campos) nem tenta reconciliar divergência entre o que já está salvo aqui e o
que o editor está mandando — diferente do GPA (`askGpaDivergencia`), estes
oito campos não têm conceito de "valor anterior que pode estar errado": cada
exame é uma visita nova, os valores vêm do software oficial da FMF na hora,
não há o que perguntar à médica.

## Laudo — Morfológico de 1º Trimestre: documento próprio, mesma paleta do evolutivo

2026-09-28, mesma conversa da reversão do azul acima. Depois de ver o preview
do relatório evolutivo, a médica decidiu que o 1º trimestre precisa do
**próprio PDF** — a gestante guarda esse documento na pasta dela, gerado uma
vez, na janela de 11-14 semanas. Não é uma seção a mais dentro do relatório
evolutivo (que continua existindo sem mudança de mecânica a partir do 2º
trimestre) — é um documento novo, mesma paleta roxo/lilás/dourado, gerado
pelo mesmo mecanismo de impressão.

- **Botão `#btn-laudo-1tri`**, ao lado de "Relatório PDF" na aba Resumo —
  só aparece com exame na janela de 11-14 semanas (`_temExame1Tri`, a mesma
  função que já decide `#charts-1tri` na aba Gráficos — nenhuma segunda
  régua). `setTab()` e o reset de `renderPatientScreen()` tratam esse botão
  igual aos outros dois.
- **Modal próprio** (`#modal-laudo-1tri`), não reaproveita `#modal-relatorio`
  — o botão "Gerar PDF" de lá já tem `onclick="confirmarGerarPDF()"` fixo, e
  fazer o mesmo modal servir dois fluxos com estado é mais risco do que
  duplicar uma casca rasa.
- **`abrirPreviewLaudo1Tri()`/`confirmarGerarLaudo1TriPDF()`** espelham
  `abrirPreviewRelatorio()`/`confirmarGerarPDF()` — mesmo CSP, mesmo
  `<body onload="window.print()">`, mesma `_abrirJanelaImpressao()` (que
  ganhou um 3º parâmetro opcional `salvarFn`, default
  `_salvarRelatorioGerado`, pra este fluxo passar `_salvarLaudo1TriGerado`
  no lugar sem duplicar a função inteira). **Sem textarea de Conclusão
  editável** — não é narrativa que evolui, é achado + gráfico de referência.
- **`_buildLaudo1TriSheetHtml()`** ancora a IG e a data no exame **mais
  recente dentro da janela 10-15 semanas**, não no último exame da gestação
  — o documento é sobre aquela visita específica, mesmo que a gestação já
  tenha avançado quando for reimpresso. Usa `_relHeaderHtml()` com o novo 2º
  parâmetro opcional `kicker` (default `'Relatório evolutivo'`, aqui
  `'Laudo — Morfológico de 1º Trimestre'`) e reaproveita `_relIdentHtml()`/
  `_relFooterHtml()` sem mudança nenhuma.
- **8 gráficos de referência, SVG, mesmas classes `.efw-*` do resto do
  relatório** (banda P10-P90 + mediana + ponto do paciente, sem CSS novo):
  `_buildRel1TriChartSvg(cfg)` é o motor genérico (grade+banda+curvas+pontos,
  no molde de `_buildRelChartEfwSvg`/`_buildRelChartUtaSvg`) e 5 funções finas
  (`_rel1TriChartFcSvg`/`CcnSvg`/`TnSvg`/`DbpSvg`/`DvSvg`) montam `ref`/`pts`
  a partir das mesmas tabelas portadas ontem pro app (`crlFromGAdays_hyett`,
  `HADLOCK_CCN_GA_DAYS`, `TN_TABLE`+regressões, `DBP_TABLE_WEEKS`, `DV_TABLE`,
  `interpTabelaRef`) — usadas até aqui só pelos gráficos em Canvas da tela.
  As 3 uterinas (E/D/média) reaproveitam `_buildRelChartUtaSvg()` (já
  existente) tal qual, com `_relPontosUterinasLado()` (variante por lado de
  `_relPontosUterinas`, que só devolvia a média) alimentando cada uma.
- **Múltipla: os 5 gráficos "estreitos" se repetem por feto**, usando
  `feto-card--a` (roxo) pro primeiro e `feto-card--b` (dourado) pro
  segundo/terceiro — **não** `feto-card--unica`, que apesar do nome é
  dourado (mesma cor de `--b`); só `--a` é roxo. Uterinas continuam 3 cards
  só, fora do laço — é medida materna, não duplica por feto.
- **Cartões de risco reaproveitados da tela**: `renderRiscoFmfCards()`
  (aba Gráficos) foi dividida em `_riscoFmfCardsHtml(gestacao, allExams)`
  (monta a string, com a regra de monocoriônica — um cartão só — já
  documentada acima) + `renderRiscoFmfCards()` (só faz `wrap.innerHTML =`).
  O laudo novo chama a mesma `_riscoFmfCardsHtml()` direto, sem precisar de
  nó no DOM. `.risco-fmf-card*` ganhou cópia em `_relPrintStyleBlock()` (o
  documento exportado é standalone — não herda o `<style>` da SPA) com a
  paleta própria do relatório (`--roxo`/`--dourado`, não `--sage`/
  `--peach-warm`, que não existem lá).
- **Segunda via**: `_salvarLaudo1TriGerado()` é cópia de
  `_salvarRelatorioGerado()`, mesmo bucket `relatorios`, sufixo `_1tri` no
  nome do arquivo (`{data}_{hora}_1tri.html`) pra não colidir com o regex de
  listagem do evolutivo. `abrirRelatoriosModal()` agora lista as duas
  famílias de arquivo em seções separadas ("Relatórios evolutivos" / "Laudos
  de 1º trimestre") — nenhuma migração nova, a RLS por `auth.uid()` já cobre
  qualquer nome de arquivo dentro da pasta do usuário.

### Evolutivo: uma linha sobre a pré-eclâmpsia do 1º trimestre

O relatório evolutivo (2º trimestre em diante) não ganhou o laudo inteiro —
só uma menção ao risco de pré-eclâmpsia apurado no 1º trimestre, porque é
o achado que orienta AAS profilático e vigilância Doppler pelo resto da
gestação (T21/T18/T13 não são mencionados lá: são assunto resolvido no
momento do rastreio, não da vigilância de crescimento contínua).

`_achadoRiscoPreEclampsia1Tri(exams)` é independente de
`avaliarRiscoPreEclampsia()` (que lê o Doppler uterino do exame **atual**) —
lê `risco_pre_eclampsia` (rastreio combinado da FMF, digitado uma vez, 11-14
semanas). Os dois podem aparecer juntos na Conclusão, são achados de origem
diferente. Reaproveita `_riscoLinhaTexto()` sem nenhuma mudança nela — só
mais um achado no mesmo formato dos outros (colo curto, IP-uterinas, TAPS).

- `_gerarConclusaoUnicaInicial(impressao, exams)` já recebia `exams` — soma a
  linha direto, sem parâmetro novo.
- `_gerarConclusaoGemelarInicial()` ganhou um 4º parâmetro
  `riscoPreEclampsia1Tri`, computado no único call site
  (`_abrirPreviewRelatorioMultiplo`) como `_achadoRiscoPreEclampsia1Tri(allExams)`
  — mesmo padrão de `taps = avaliarTAPS(gestacao, allExams)`, calculado do
  lado de fora e passado pronto.

### O laudo de 1º trimestre também ganhou Conclusão

Mesmo dia, a médica mandou um print do laudo antigo (editor de laudos) com a
"Impressão Diagnóstica" em lista — o laudo novo daqui tinha ficado sem
Conclusão nenhuma (decisão inicial: "não é narrativa que evolui"). Ela quis
de volta, no mesmo formato de checklist.

`_gerarConclusaoLaudo1TriInicial(gestacao, allExams, exame1Tri)` monta o
rascunho — mesmo padrão de textarea editável no preview / `<ul class="rel-
lista">` estática no PDF final que o evolutivo já usa
(`_relListaHtml`/`opts.textareaMode`, sem nenhuma mudança nas duas). Cada
linha só afirma o que o app realmente tem:

- Tipo de gestação + IG, a partir do exame de 1º trimestre (não do mais
  recente da gestação — mesma âncora do resto do documento).
- Anomalia estrutural: frase padrão, sempre igual (editável).
- Cromossomopatias: **não afirma "baixo risco"** — o app não calcula esse
  julgamento. A frase aponta pros gráficos de referência e pros cartões de
  risco (números crus da FMF), quem decide "baixo"/"aumentado" é quem lê,
  não o texto gerado. Diferente do print que a médica mandou (que dizia
  "baixo risco" direto) — ela edita essa linha quando quiser afirmar isso.
- IP médio das uterinas: percentil de verdade, via
  `_relPontosUterinasLado(gestacao, allExams, 'media')` (a mesma função dos
  3 gráficos de uterinas) — só entra se houver medida.
- Pré-eclâmpsia: o valor de `risco_pre_eclampsia` digitado, sem qualificar
  "baixo"/"aumentado" pelo mesmo motivo da linha de cromossomopatias.
- Colo: reaproveita `avaliarRiscoColoCurto()` — precisa de `_gaW` no objeto
  do exame (a função não calcula sozinha), então monta um clone do exame só
  com esse campo antes de chamar (`{...exame1Tri, _gaW: igDays/7}`). Colo
  curto vira a mesma frase sublinhada de sempre (`_riscoLinhaTexto`); normal
  vira "Colo uterino sem anormalidades (X mm)"; sem medida, a linha nem
  entra.

### Ducto venoso do 1º trimestre: eixo X é idade gestacional, não CCN

2026-09-27, um dia depois de publicado. O gráfico "IP — Ducto Venoso" dos 8
de referência saiu como IP × CCN — cópia fiel do gráfico do editor de laudos
(`morfologico-1trimestre.html`, `cfgs.push({...xLabel:'CCN (MM)'...})`, a
mesma fonte de onde `DV_TABLE` foi portada). A médica corrigiu: o eixo certo
é idade gestacional, como os outros quatro gráficos "estreitos" (FC, DBP) —
só TN continua em CCN de propósito, porque a tabela de referência da própria
clínica já vem nesse eixo. **O mesmo erro existia no editor** — corrigido lá
também, no mesmo dia, com o mesmo par de mudanças (ver `CLAUDE.md` do
`laudos-dramorgana`).

`DV_TABLE` é uma leitura visual do gráfico de Pruksanusak et al. (2014), cujo
eixo original já é CCN (mm) — os valores da tabela continuam válidos, não são
o que estava errado. O conserto não trocou a tabela, só a converteu para o
eixo certo na hora de desenhar: em vez de plotar direto `x = CCN`, cada ponto
da curva de referência agora varre semanas (`w`, 11 a 14, mesma janela do
gráfico de CCN vizinho) e usa `crlFromGAdays_hadlock(w*7)` — a mesma função
que já converte GA→CCN para a curva de CCN×IG — para achar o CCN equivalente
e só então consultar `DV_TABLE` por ele. O ponto da paciente trocou de `{x:
e.ccn, y: e.dv_ip}` para `{x: w, y: e.dv_ip}` (`w` = IG do exame, não o CCN
medido) — mesmo padrão que FC e DBP já usavam.

Dois lugares, os dois com o mesmo par de mudanças: `buildChart1TriDV`
(Canvas, tela) e `_rel1TriChartDvSvg` (SVG, laudo PDF) — mais o título do
card em cada um (`#card-1tri-dv` na tela, `_REL_1TRI_CHARTS` no PDF), de "×
CCN" para "× Idade Gestacional".

### Os 5 gráficos "estreitos" do 1º trimestre viraram reta, não curva suave

Mesma conversa. A médica notou, olhando o gráfico de ducto venoso já com o
eixo corrigido: as linhas ainda saíam curvas, e o editor de laudos (de onde
esses 8 gráficos foram portados) sempre desenhou reta ponto-a-ponto —
`buildGraficoCard()` lá usa só `M`/`L` (`pathFromPts`), nunca curva. Aqui os
dois motores de desenho (`_relSvgPath` no PDF, `_smoothPath` dentro de
`_drawChart` na tela) suavizam todo mundo com Catmull-Rom→Bézier — inclusive
os 5 gráficos estreitos (FC, CCN, TN, DBP, DV), cuja referência vem de tabela
esparsa (poucos pontos: `DV_TABLE` tem 11, `DBP_TABLE_WEEKS` só 4) já
interpolada linearmente antes de chegar no desenho. O Catmull-Rom por cima
de uma reta já pronta inventa uma curvatura que a tabela original não tem —
mais visível quanto mais esparsa a tabela, e foi exatamente no ducto venoso
que ela notou.

**Não mudei o motor de suavização em si** (`_relSvgPath`/`_smoothPath`
continuam Catmull-Rom, do jeito que sempre foram) — mudei só quem os 5
gráficos estreitos chamam:

- PDF (`_buildRel1TriChartSvg`): duas funções novas, `_relLinearPath()` e
  `_relLinearBandPath()`, mesmo estilo do `pathFromPts` do editor (`M`/`L`
  puro) — usadas só aqui, não em `_relSvgPath`/`_relBandPath` (que
  continuam servindo o gráfico grande de peso e as uterinas do relatório
  evolutivo, sem mudança nenhuma).
- Tela (`_drawChart`): ganhou `cfg.linear` (opcional, default `false`) — com
  `true`, troca `_smoothPath` por `_linePath` (mesma lógica, sem Bézier).
  `buildChart1TriFC`/`TN`/`Dbp`/`DV` passam `linear: true`; `buildChart1TriCcn`
  não (ver seção seguinte — o CCN acabou sendo a exceção); todo o resto que
  chama `_drawChart` (grid padrão ≥15 semanas, `_drawThresholdChart` etc.) não
  passa o parâmetro, então continua suave como sempre.

**As 3 uterinas dentro do mesmo grid 4×2 continuam suaves, de propósito.**
Elas reaproveitam `_buildRelChartUtaSvg()`, a mesma função do relatório
evolutivo (não é código novo deste bloco) — mudar o estilo dela mudaria
também o gráfico de uterinas usado do 2º trimestre em diante, que ninguém
pediu para mexer. A curva delas vem de fórmula contínua (Gómez et al.,
amostrada a cada 0,5 semana) e não de tabela esparsa, então a suavização não
cria o mesmo artefato — a inconsistência visual dentro do mesmo grid (5
retas + 3 curvas) é o preço de não tocar num componente compartilhado sem
pedido explícito.

### CCN×IG virou serrote com reta — a exceção que provou a regra

Mesmo dia, poucas horas depois. A médica reportou o CCN×IG (não o ducto
venoso desta vez) "todo irregular", com print mostrando dentes de serrote
nítidos na banda e na mediana. A causa não é a mesma da seção anterior — é o
oposto: ali a reta corrigia uma curva que inventava suavidade sobre poucos
pontos reais; aqui a reta **revelou** um degrau que sempre existiu na
referência, só que o Catmull-Rom antigo escondia arredondando os cantos.

`crlFromGAdays_hadlock()` interpola `HADLOCK_CCN_GA_DAYS`, uma tabela densa
(77 linhas) mas **arredondada** — CCN em mm inteiro, IG em dias inteiros.
Amostrada a cada 0,1 semana (0,7 dia) pro gráfico, o incremento de CCN entre
pontos consecutivos varia muito (0,7mm, depois 2,7mm, depois 0,7, 0,7, 1,7…)
porque o arredondamento da tabela não anda em passo constante com o dia —
conferido ponto a ponto (`node`, deltas de P50 saltando entre 0 e 2,7mm sem
padrão). É ruído de arredondamento de uma grandeza que na vida real cresce
suave (o feto não "acelera e desacelera" a cada 0,7 dia) — diferente do
ducto venoso, cuja tabela (`DV_TABLE`, 11 pontos) é genuinamente esparsa e
onde cada segmento reto liga dois dados reais, sem nada inventado no meio.

Por isso o CCN×IG é o único dos 5 gráficos estreitos que **não** foi pro
lado da reta — ficou com a suavização de sempre (Catmull-Rom), a mesma que
FC/DBP/DV/TN perderam. `_buildRel1TriChartSvg` ganhou `cfg.smooth` (default
`false` = reta; só `_rel1TriChartCcnSvg` passa `true`) e `_drawChart` só
recebe `linear: true` de `buildChart1TriFC`/`TN`/`Dbp`/`DV` — `buildChart1TriCcn`
ficou de fora, voltando a usar `_smoothPath`/`_relSvgPath` como antes de
2026-09-27. A tabela em si (`HADLOCK_CCN_GA_DAYS`) e a função de interpolação
não mudaram — nenhuma conta de datação por CCN foi tocada, só o desenho da
faixa de referência.

**Critério pra decidir reta vs. suave num gráfico novo:** poucos pontos reais
e bem espaçados (DV, DBP) → reta, é o que o dado tem; fórmula fechada e
contínua (FC) → reta já sai suave sozinha, tanto faz; tabela densa mas
arredondada representando algo que cresce contínuo (CCN) → suave, porque o
arredondamento não é sinal, é ruído de captura.

### CCN×IG: a suavização escondia o degrau, mas inventava outra coisa — a curva foi pra raiz

2026-09-27, mesmo dia, mais tarde ainda. A médica reportou de novo: as linhas
do CCN×IG (mediana e as duas bordas da banda) saíam "serpiginosas" —
onduladas, não retas — e pediu também mais respiro na faixa P10-P90, achatada
demais pro ponto da paciente aparecer bem.

A primeira parte não é um problema novo, é o mesmo problema da seção anterior
por outro ângulo. O Catmull-Rom escondia o degrau do arredondamento da tabela
(a reta virava suave), mas Catmull-Rom por cima de uma sequência de segmentos
com inclinação errática (o próprio degrau: 0,7mm, 2,7mm, 0,7, 0,7, 1,7mm...)
não produz uma curva parecida com o crescimento real — produz uma curva que
ziguezagueia tentando concordar com cada inclinação diferente, e isso *é* a
serpentina. Trocar reta por suave só troca a aparência do mesmo ruído; não
tira o ruído do caminho. A decisão de manter o CCN suave (seção anterior)
resolvia o sintoma errado.

**A correção foi na tabela, não no desenho.** `crlFromGAdays_hadlock()`
deixou de interpolar `HADLOCK_CCN_GA_DAYS` ponto a ponto e passou a ler uma
parábola ajustada por mínimos quadrados sobre a tabela inteira (`quadRegress`,
mesma ideia do `linRegress` que já resolvia esse problema pro `TN_TABLE` —
só que ali uma reta bastava e aqui não, porque o CCN acelera com a IG).
Erro máximo da parábola contra os 77 pontos da tabela: ~1,6mm — e boa parte
disso é inevitável, não é erro da regressão: a própria tabela tem o mesmo dia
de GA arredondado pra CCNs vizinhos (ex.: GA=78 aparece para CCN 42, 43 *e*
44), e nenhuma função de um valor só passa pelos três. O erro fica bem abaixo
da banda (±9 a ±15mm na janela de 11-14 semanas), então não muda leitura
clínica nenhuma — só troca "77 segmentos com inclinação aleatória" por uma
curva contínua de verdade. Com a fonte do ruído removida, `cfg.smooth`
deixou de fazer sentido pro CCN: ele voltou a usar reta
(`_relLinearPath`/`_relLinearBandPath` no PDF, `linear: true` no
`_drawChart` da tela), igual aos outros 4 — a amostragem em passos de 0,1
semana já é fina o bastante pra uma parábola parecer suave sem precisar de
Bézier por cima. **O "critério pra decidir reta vs. suave" da seção anterior
fica errado pro CCN especificamente** — valia enquanto a única fonte
disponível era a tabela arredondada; deixa de valer assim que existe uma
curva contínua ajustada a ela. Continua valendo pra DV/DBP (tabela
genuinamente esparsa, sem regressão feita) e FC (fórmula fechada).

**A faixa P10-P90 achatada é outra causa, e não tinha arrumo no desenho.** A
mediana do CCN sobe ~40mm em 3 semanas (11 a 14 semanas); a banda em qualquer
ponto x é bem mais estreita que isso (±9 a ±15mm). Como o eixo Y do gráfico
tem que caber a subida inteira da mediana, a banda ocupa só uma fração da
altura do card em qualquer ponto — reduzir a folga ao redor (já feito hoje
mais cedo, ver "Laudo 1º trimestre: reduz a folga vertical") não muda essa
proporção, só o espaço morto nas bordas. A única forma de dar mais respiro
sem inflar a banda estatística (que seria inventar precisão que a
aproximação ±(2+0,16×CCN) não tem) é aumentar o card fisicamente:
`_buildRel1TriChartSvg` ganhou `cfg.vh` (altura do viewBox, default `176`,
igual a antes) e só `_rel1TriChartCcnSvg` passa um valor maior (`230`) — mais
pixel por mm sem mudar o que a faixa significa. Escopado só ao CCN, de
propósito: os outros 4 não foram tocados, ninguém pediu. Efeito colateral
aceito: na grade 4×2 do laudo (FC/CCN/TN/DBP na primeira linha), o CSS Grid
estica os três vizinhos pra acompanhar a altura do card do CCN — como
`.feto-card` não é flex, a sobra vira um respiro em branco no rodapé deles,
não distorce nada. Só o PDF; a tela (`buildChart1TriCcn`, Canvas) já usa um
container quadrado (`aspect-ratio:1/1`, compartilhado por todos os cards de
gráfico) — mais alto proporcionalmente que o card largo do PDF — e não foi
mexida.

### Os 5 gráficos "estreitos" não mostravam a tag de percentil — só os de ≥15 semanas mostravam

2026-09-27, mesmo dia. A médica notou que a pequena tag "Pxx" que aparece
acima de cada ponto nos gráficos padrão (biometria/EFW, ≥15 semanas) não
aparecia nos 5 gráficos "estreitos" do 1º trimestre (FC/CCN/TN/DBP/DV) — nem
na tela (`#charts-1tri`) nem no PDF do Laudo 1º Trimestre. Não era regressão:
esses 5 nunca tiveram a tag, por uma decisão registrada no próprio código na
hora em que os builders SVG foram escritos ("Nenhum dos 5 tem percentil de
verdade... só a bolinha, sem 'Pxx' em cima") — a banda desses gráficos vem de
uma aproximação P10/P50/P90 (Hyett/Hadlock/tabela da clínica/Pruksanusak), não
de uma tabela de z-score publicada como as do gráfico padrão, e por isso não
tinham percentil calculado para mostrar.

A médica quis a tag mesmo assim — ela já usa a mesma aproximação
P10/P50/P90 para decidir se um ponto está dentro ou fora da faixa; só faltava
transformar isso num número. `_pctAprox(val, p10, p50, p90)`, novo, no início
da seção "1º TRIMESTRE — referências da página de risco/gráficos da FMF",
reaproveita a mesma fórmula que o **editor de laudos** já usa para o selo de
cada marcador (z-score assumindo distribuição simétrica em torno da mediana,
`normalCDF` via `_pnorm` — já existente aqui, usado noutros cálculos —,
clampado em [5,95]): é uma aproximação, igual à banda que a origina, não uma
tabela de referência nova.

- **Canvas (tela)**: os 5 `buildChart1Tri*` já computam p10/p50/p90 dentro do
  próprio extractor de `patientPoints` (a mesma fórmula que já monta `refData`
  para aquele x) — só precisou passar `p: _pctAprox(val, p10, p50, p90)` junto
  de `x`/`y`. `_drawChart` **não mudou**: já suportava `pt.p` desde os
  gráficos padrão, só nunca tinha sido alimentado por estes 5.
- **SVG (PDF)**: os 5 `_rel1TriChart*Svg` ganharam o mesmo cálculo. O motor
  `_buildRel1TriChartSvg` **não tinha nenhum código de tag** (só desenhava a
  bolinha) — ganhou a mesma lógica dos gráficos padrão
  (`_buildRelChartSvg`/`_buildRelChartEfwSvg`): um `<text class="efw-pt-t">`
  antes do `<circle>`, com a mesma regra de colisão (dois pontos a menos de
  28px um do outro — no eixo já desenhado — só o mais recente ganha o
  rótulo). `.efw-pt-t` já existia no CSS (tela e `_relPrintStyleBlock`), então
  não precisou de nenhuma classe nova.
- **Uterinas (3 cards, `buildDopplerChart`/`_buildRelChartUtaSvg`) continuam
  sem tag, fora de propósito.** Esse motor nunca calculou percentil algum em
  lugar nenhum do app (nem nos gráficos padrão de uterinas ≥15 semanas) — não
  é uma inconsistência introduzida aqui, é o comportamento de sempre da
  família Doppler/uterinas. Adicionar percentil ali seria mudar um componente
  usado do 2º trimestre em diante, sem pedido.
- Testado (Playwright, sem depender de login/Supabase): chamada direta das 5
  funções SVG com exames fictícios confirma `<text class="efw-pt-t">P\d+`
  presente nas 5; um monkeypatch de `_drawChart` confirma que os 5
  `patientPoints` chegam com `.p` preenchido. Smoke test da página inteira sem
  erro novo no console.

### "Relatório PDF" saía achatado num exame só de 1º trimestre — porque não tinha nada pra mostrar

2026-09-27, mesmo dia, depois do conserto acima. A médica comparou os dois
botões pro **mesmo** exame (morfológico de 1º trimestre, sem nenhum exame
≥15 semanas ainda): "Laudo 1º Trimestre" saiu bonito (é o documento novo,
Parte 4 do plano); "Relatório PDF" saiu com os cards de CC/Circ. abdominal/
Fêmur/Peso "achatados". Não era a banda de referência apertada (o conserto
de altura de mais cedo, `d66939a`, continuava intacto e publicado havia
mais de duas horas — conferido via `actions_list` do GitHub, deploy
`success` em ambos os commits) — era o card renderizando **sem nenhum ponto
da paciente**, só a banda P10-P90 pura de 15 a 40 semanas. Confirmado com
Playwright, chamando `_buildRelSheetHtml` de verdade com um exame fictício
de 12s5d: os quatro cards saíam com badge "—" no cabeçalho e "—" nas quatro
colunas do Histórico biométrico — código correto (nada quebrado), só
mostrando uma referência que não descreve aquela visita.

**A causa:** `_relPatientPoints`/o extractor de `_buildRelChartEfwSvg` já
filtram exame com IG < 15 semanas (`if (w < 15) return null` / `if (semanas
< 15) return null`) — mesmo corte do resto do app. Um exame de 1º trimestre
nunca teria ponto nenhum nesses quatro cards, e SÓ o card de uterinas (janela
11-41 semanas, ver "IP das uterinas" acima) já tinha o guard certo:
`_buildRelChartSvg` recusava (`return null`) o card `'uta'` sem ponto, mas
CC/CA/Fêmur/Peso não tinham o mesmo guard — desenhavam a banda mesmo vazios.

**O conserto**, os dois na mesma linha de raciocínio do guard que 'uta' já
tinha:
- `_buildRelChartSvg`: o `if (paramKey === 'uta' && !patPts.length) return
  null;` virou `if (!patPts.length) return null;` — vale pros quatro
  paramKeys que essa função atende (`cc`/`ca`/`fl`/`efw`, este último só na
  página de trigemelar), não só uterinas.
- `_buildRelChartEfwSvg` (o gráfico grande de peso, única/gemelar): ganhou o
  mesmo `if (!pts.length) return null;`, que não existia.
- `_buildRelSheetHtml`: a seção "Evolução longitudinal" inteira (cabeçalho +
  legenda) só aparece se sobrar pelo menos um card (`smallCells.length ||
  bigCells.length`) — sem isso, um exame sem NENHUM card (nem uterinas)
  imprimiria o cabeçalho da seção sozinho, sem gráfico nenhum embaixo.

Testado: o mesmo exame de 12s5d (com uterinas medidas) agora imprime só o
card "IP médio · art. uterinas" com o ponto certo — os quatro cards vazios
somem. Um exame de 21 semanas (única, com CC/CA/Fêmur/peso reais) continua
saindo com os quatro cards, idêntico a antes — testado lado a lado, sem
diferença.

**Ficou de fora, de propósito:** a tabela "Histórico biométrico"
(`_buildRelHistoricoUnicaHtml`) continua imprimindo "—" nas colunas PFE/CA/
CC/FÊMUR pra uma visita de 1º trimestre — ela lista TODOS os exames da
gestação, não só os ≥15 semanas, e não foi isso que a médica reclamou. Existe
um precedente pra esconder coluna 100% vazia (a coluna Colo do histórico, ver
"Colo curto e pré-eclâmpsia são da gestação, não do feto" — "coluna inteira
de '—' é ruído") que poderia se aplicar aqui também (esconder PFE/CA/CC/FÊMUR
por completo numa gestação só com exames de 1º trimestre), mas isso é
extensão de escopo — revisitar se ela pedir.

### Margens da página impressa: 40px (10,6mm) laterais, e só 18px (4,8mm) no rodapé

2026-09-27, mesmo dia. A médica relatou "os textos encostam na borda" no
PDF. `@page{size:A4;margin:0}` — a margem real de toda folha exportada
(`.sheet`/`.sheet-flow`, os dois sem padding próprio) vem inteira do
padding/margin de `.hdr`/`.body`/`.ftr`, que são os únicos elementos que
tocam as quatro bordas da folha (`.hdr` encosta no topo, `.ftr` encosta no
fim, os três têm `margin:0 40px` nas laterais). Medido com Playwright
(`getBoundingClientRect` contra a `.sheet-flow`, em `media: print`, convertido
de px pra mm a 96px/polegada): **10,6mm nas laterais, ~6,9mm no topo
(padding-top do `.hdr`), e só ~4,8mm no rodapé** (padding-bottom do `.ftr`,
o mais apertado dos quatro) — fino demais pra um documento impresso, e o
rodapé próximo o bastante da margem não-imprimível física de muita
impressora pra realmente "encostar".

**O conserto foi só nesses três seletores**, replicado nas duas cópias do
CSS (`.rel-preview .hdr/.body/.ftr`, pro preview em tela, e a versão sem
prefixo dentro de `_relPrintStyleBlock()`, pro documento exportado — as
duas precisam bater, senão a tela mostra uma margem e o PDF sai com outra):
`margin:0 40px` → `0 48px` (10,6mm → 12,7mm), `.hdr` `padding-top:26px` →
`30px` (6,9mm → 7,9mm), `.ftr` `padding-bottom:18px` → `24px` (4,8mm →
6,3mm). Não mexeu em `.body`'s padding-top (22px, é espaçamento interno
entre o fim do cabeçalho e o começo do conteúdo, não margem de página) nem
em nenhuma medida de gráfico ou tabela.

**Verificado que não estoura a página mais apertada.** `.sheet` (usado só
na página de gráficos por feto da trigemelar — a única com altura fixa
297mm + `overflow:hidden`, que corta em silêncio o que não couber) tinha
~108mm de folga entre o conteúdo natural e o limite da folha antes deste
conserto; a margem lateral maior estreita o conteúdo em ~8px, folga de
sobra pra absorver sem chegar perto do corte. `.sheet-flow` (evolutivo
única/gemelar/trigemelar e Laudo 1º Trimestre) nem tem esse risco — já
estoura pra uma segunda página em vez de cortar.

### CC/CA/Fêmur do relatório evolutivo: mesmo desenho dos gráficos do 1º trimestre

2026-09-27, mesmo dia. A médica mandou o print do card "CCN × Idade
Gestacional" do Laudo 1º Trimestre e pediu CC/CA/Fêmur (≥15 semanas) no
mesmo desenho: grade horizontal com o valor à esquerda, referência escrita
no card, semanas no eixo X, P90/P50/P10 rotulados na ponta, percentil em
cima do ponto — e a banda P10-P90 **larga**, como lá.

- **Mesmo motor, não uma cópia.** `_buildRelChartSvg` deixou de desenhar o
  próprio SVG (220×173, só a banda, eixo com 15/22/29/36) e passou a montar
  `ref`/`pts` e chamar `_buildRel1TriChartSvg`. O motor ganhou três opções,
  todas desligadas por padrão (os 5 gráficos do 1º trimestre saem iguais —
  conferido comparando o SVG antes/depois, só mudou uma linha em branco):
  `vw` (largura do viewBox — 240 aqui, porque na grade de 3 colunas o 340
  padrão deixava todo texto miúdo), `trace` (a linha ligando as visitas, que
  o card antigo já tinha) e `smooth` (já existia; aqui ligado porque a
  tabela do Hadlock é semanal, a mesma curva suave de antes).
- **A banda larga vem da janela, não da altura.** O card do 1º trimestre
  cobre 3-4 semanas; num eixo fixo de 15 a 40 semanas a mediana de CC sobe
  ~250mm e a banda de ±10-12mm vira fio — foi por isso que o card de CC/CA/
  Fêmur ainda parecia achatado mesmo depois do `PLOT_H 100→155` (`d66939a`).
  O eixo X agora acompanha os exames: da primeira visita −3 semanas à última
  +3, no mínimo 6 semanas de largura, sempre dentro de 15-40
  (`JANELA_PAD`/`JANELA_MIN`). **Consequência que é física, não bug:** com
  uma visita (o caso do morfológico de 2º trimestre) a banda fica larga como
  no 1º trimestre; com visitas espalhadas por 12+ semanas o eixo precisa
  caber o crescimento inteiro e a banda volta a estreitar. Se ela reclamar
  disso no evolutivo com muitas visitas, as saídas são outras (recortar só em
  volta da última visita e perder as antigas do gráfico, por exemplo) — é
  escolha dela, não ajuste de proporção.
- **Rótulos P90/P50/P10 com distância mínima** (10 unidades), mesma regra de
  `_buildRelChartUtaSvg`: com a banda estreita do caso de muitas visitas os
  três saíam empilhados. Nos gráficos do 1º trimestre as curvas já terminam
  mais afastadas que isso, nada muda.
- **Percentil em cima do ponto é o do app, não aproximação** — `calcBiometria`
  (CC/CA/Fêmur), `calcEFWPercentile` (peso, na página por feto da
  trigemelar, que também passa por esta função) — o mesmo número do selo do
  cabeçalho e da tabela do histórico. Diferente dos 5 do 1º trimestre, que
  usam `_pctAprox` por não terem tabela de percentil.
- **Subtítulo com a referência e a unidade** (`_REL_CHART_SUB`): "Referência
  Hadlock 1984 · mm" — a grade agora imprime valores, e o histórico logo
  abaixo mostra em cm; sem a unidade "190" não diz qual das duas. Entrou nos
  cards da única e nas células da página por feto da trigemelar.
- Só o relatório PDF (e o preview dele) mudou. Os gráficos da aba Gráficos
  (Canvas, `buildChart`) não foram tocados.

## Risco combinado da FMF: parto prematuro e diabetes gestacional entraram junto com T21/T18/T13/pré-eclâmpsia

2026-09-27, conversa seguinte. A médica pediu os dois riscos que o software
novo da FMF passou a devolver no mesmo rastreamento combinado do 1º
trimestre. Achou, ao pedir, que TN/FC/T21/T18/T13/pré-eclâmpsia não existiam
aqui — na verdade só não tinha reparado no `<details>` colapsado "Risco 1º
Trimestre — FMF" do formulário de exame (fácil de passar batido: fica junto
de Doppler/Colo, que também começam fechados). Confirmado com ela: os quatro
já existentes ficam como estão, só entram os dois novos, no mesmo formato
("1 em X", texto livre) e no mesmo padrão dos que já existiam — sem inventar
uma segunda forma de captura pro que é, na prática, o mesmo tipo de campo.

`risco_parto_prematuro`/`risco_diabetes_gestacional` (migração 013) seguem
exatamente o desenho de `risco_pre_eclampsia`, não o de `risco_t21`/
`risco_t18`/`risco_t13`: são **achado materno da visita**, um valor só por
gestação (mesmo numa gemelar/trigemelar — o rastreamento combinado não é por
feto), lidos sempre do formulário na tela via `sharedStr`, nunca do rascunho
de outro feto quando o médico alterna de feto no meio do preenchimento —
mesma razão de `colo`/`aut_e`/`aut_d`/`risco_pre_eclampsia` ficarem fora de
`_ME_FETO_FIELD_IDS`. Os pontos que replicam `risco_pre_eclampsia` porque o
campo é desse tipo (materno, opt-in, texto livre): `_EXAM_COLUMNS`,
`_meClearBioFields`, `openEditExamModal` (`fmt1TriMap`), `_meBuildExamData`,
`validateImportedDB` (restauração de snapshot/import).

- **Cartões de risco** (`_riscoFmfCardsHtml`): os três achados maternos
  (pré-eclâmpsia, parto prematuro, diabetes gestacional) viraram um `.map()`
  sobre `[classe, rótulo, campo]` em vez de três blocos HTML literais quase
  idênticos — a duplicação que já existia com um só (`preE`) virava
  triplicação com três. Classes CSS novas `--pp`/`--dg`, mesma cor que `--pe`
  nas duas cópias de estilo (tela e `_relPrintStyleBlock` do PDF): são o
  mesmo tipo de achado (rastreamento materno da FMF), inventar uma cor por
  campo sugeriria uma hierarquia de gravidade que não existe entre os três.
- **Conclusão do laudo de 1º trimestre** (`_gerarConclusaoLaudo1TriInicial`):
  duas linhas a mais no checklist, mesmo texto/formato da linha de
  pré-eclâmpsia ("Rastreamento combinado do 1º trimestre: risco de X para
  Y..."), sem qualificar "baixo"/"aumentado" — mesmo motivo já documentado
  pra pré-eclâmpsia e cromossomopatias: quem decide isso é quem lê, o app só
  repete o número que o software da FMF devolveu.
- **Relatório evolutivo** (`_gerarConclusaoUnicaInicial`/
  `_gerarConclusaoGemelarInicial`): duas funções novas,
  `_achadoRiscoPartoPrematuro1Tri`/`_achadoRiscoDiabetesGestacional1Tri`,
  cópia de `_achadoRiscoPreEclampsia1Tri` — mesmo formato `{label, conduta}`
  consumido por `_riscoLinhaTexto` sem nenhuma mudança nela. Na múltipla,
  `_gerarConclusaoGemelarInicial` ganhou dois parâmetros a mais (mesmo
  padrão do `riscoPreEclampsia1Tri`: calculado fora, em
  `_abrirPreviewRelatorioMultiplo`, e passado pronto — não vive dentro do
  `impressao` de nenhum feto, é achado da gestação).


## Referência da translucência nucal (TN): tabela FMF, sem "tabela da clínica"

2026-09-29. O subtítulo dos gráficos de TN dizia "Tabela de referência da
clínica" — sem fonte citável, inadequado para um laudo. A médica enviou a
tabela P5/P50/P95 por CCN (45–84 mm, 2 casas decimais) e `TN_TABLE` foi
substituída por ela; o subtítulo (tela e PDF) passou a "Referência FMF (Wright
et al., 2008)". A curva continua sendo a reta de mínimos quadrados sobre a
tabela (erro máximo 0,05 mm). A atribuição a Wright 2008 foi proposta por Claude e **confirmada pela médica em 2026-09-29**. O editor de laudos tem o
mesmo subtítulo e a mesma tabela antiga. **DBP precoce (12–15 sem):** mesma data, mesma troca. A médica enviou média ±
1 DP por semana (12–16 sem, Hadlock, DP ≈ 3 mm aproximado) e `DBP_TABLE_WEEKS`
passou a guardar P5/P50/P95 = média ∓ 1,645 × DP (±1 DP seria P16–P84).
Subtítulo: "Referência Hadlock" — **sem ano, porque ela não informou; confirmar a
publicação exata.** Nada mais de "tabela da clínica" nos gráficos do 1º
trimestre.

**Ducto venoso de 1º trimestre — fonte confirmada pela médica em 2026-09-29:**
Pruksanusak N, Suntharasaj T, Suwanrath C, Phukaoloun M, Kor-anantakul O,
Geater A. *A reference for ductus venosus blood flow at 11–13+6 weeks of
gestation.* Gynecol Obstet Invest 2014;78(1):22–25. (O sobrenome é
**Pruksanusak** — a grafia "Pruksanasuk" usada antes no app estava errada e foi
corrigida.) Os valores de `DV_TABLE` continuam sendo leitura visual do gráfico
do artigo, por isso o subtítulo diz "Aproximação".

## Exame externo: entrada rápida reaproveita o modal de exame

2026-09-29, a pedido da médica: laudos de outro serviço, trazidos pela paciente,
entram no histórico para a revisão pré-exame e para as curvas de tendência.

- **Não é um formulário novo.** É o modal "Novo Exame" com a caixa "Exame externo"
  marcada — o botão "+ Exame externo" só abre o modal já marcado. Assim gemelar
  (rascunho por feto), datação e Doppler recolhido funcionam sem uma segunda cópia.
- **Migração 014** (`externo`, `servico_externo`, `efw`, `impressao_externa`).
  **Tem de estar aplicada no Supabase antes de publicar**: `_EXAM_COLUMNS` passou a
  pedir as colunas, e sem elas o bootstrap inteiro falha (e todo upsert também).
- **`efw` é o peso digitado do laudo externo, em gramas.** O código já lia
  `e.efw ?? calcEFW(...)` em ~20 lugares (percentil, gráficos, discordância) mas
  nada gravava `efw`; a coluna liga o gancho que já existia, sem tocar em nenhum
  deles. Com `efw` preenchido o percentil sai dele; sem, continua Hadlock pelas
  quatro medidas. A prévia do modal mostra os dois quando existem. Aceita peso
  sem nenhuma medida. Faixa 20–7000 g, validada em `saveExam`.
- **Por feto: `efw`** (entra em `_ME_FETO_FIELD_IDS`). **Da visita: `externo`,
  `servico_externo`, `impressao_externa`** — lidos com `sharedStr`, replicados em
  todos os registros da visita, como colo/uterinas. Sem a marca `externo`,
  `_meBuildExamData` grava `efw` nulo: nunca sobra peso digitado escondido num
  exame da casa.
- **A IG continua vindo da datação da gestação (DUM/CCN)**, não da IG impressa no
  laudo externo — o percentil é lido na régua da clínica. Só sem âncora o campo de
  IG fica editável, como sempre.
- Selo "Externo · serviço" na linha do exame/visita (`_exameExternoBadgeHtml`).
  Import/restauração de snapshot conhecem os quatro campos (`validateImportedDB`).
- **Ficou de fora, por decidir:** o exame externo entra nos cálculos e no
  "Histórico biométrico" do PDF como qualquer outro, sem marca — pode confundir
  quem lê o papel da clínica, e a medida de outro aparelho/operador tem outro erro
  (pesa na leitura de "queda de percentil"). Se ela quiser, marcar no PDF e/ou
  avisar na tendência.
- **CCN de exame externo pode datar a gestação — sem código novo de datação.** O
  painel DUM x CCN (primeiro exame) e "Editar gestação → Redatar por um exame já
  feito" já aceitam qualquer exame com CCN, externo ou não. Só entraram um
  lembrete no bloco do CCN e `_meAvisoCcnExterno`: com data já definida, avisa
  quando o CCN de um exame externo diverge da IG atual além do corte usual de
  redatação (ISUOG: > 5 dias até 8+6 sem; > 7 dias de 9+0 a 13+6). Só avisa; quem
  redata é a médica. Exame da casa não ganha aviso.
- **BCF é campo visível, junto da biometria (2026-09-29).** A coluna `fc` já
  existia (por feto) e alimenta o gráfico de BCF do 1º trimestre, mas o input vivia
  escondido no bloco recolhido "Risco 1º Trimestre — FMF", com o nome "FC", e só
  parecia servir ao 1º trimestre. Saiu de lá; vale para qualquer IG (30–250 bpm).
  **Onde aparece (mesmo dia):** coluna BCF no histórico biométrico do PDF (única:
  uma coluna; múltipla: uma por feto, porque BCF é do feto) e alerta na linha do
  exame na tela. **Alerta só abaixo de 110 ou acima de 170 bpm** (`_BCF_ALERTA_MIN/
  MAX`, decisão da médica); 110–160 é a faixa de referência, mas 160–170 não
  alerta. Coluna só existe se alguma visita mediu, valor de alerta em negrito, dado
  ausente é "—". **Ainda fora:** Resumo em tela e Conclusão não mencionam o BCF.

## 1º trimestre: sem gráfico de DBP; Feto 3 em marrom (2026-09-29)

A pedido da médica, nos dois repositórios no mesmo dia (o editor de laudos tem o
mesmo bloco de gráficos; ver o `CLAUDE.md` de lá).

- **Saiu o gráfico de DBP** da aba Gráficos (`#card-1tri-dbp`, `buildChart1TriDbp`)
  e do Laudo 1º Trimestre (`_rel1TriChartDbpSvg`, entrada de `_REL_1TRI_CHARTS`),
  com a tabela `DBP_TABLE_WEEKS`. Ficam 7 cartões: BCF, CCN, TN, Ducto Venoso e as
  3 uterinas — no PDF a grade `feto-cards--quad` já fecha 4 + 3; na tela,
  `.charts-1tri-grid` passou a 4 colunas acima de 1100px. Na múltipla, cada feto
  tem uma linha de 4. Motivo: o DBP a 11–14 semanas acrescenta pouco ao CCN, e a
  referência era a mais fraca do app (média ± DP aproximado, sem ano; o editor
  usava outra tabela, Chitty & Altman) — isso fecha também a pendência "confirmar a
  publicação exata" da seção da TN/DBP. **O campo DBP do formulário fica**: é medida
  de biometria e entra no peso a partir de 15 semanas.
- **Feto 3 da trigemelar é marrom** (`--marrom:#6F3F22`, `.feto-card--c`,
  `.feto-badge--c`, `.comparativo-item--c`, nas duas cópias do CSS). Antes
  `idx === 0 ? --a : --b` deixava o 2 e o 3 dourados. O marrom só aparece onde há
  três fetos com cor por feto (hoje, os gráficos do Laudo 1º Trimestre); as
  páginas por feto do evolutivo da trigemelar não usam cor por feto.

## Aba "Revisão": reler a paciente antes de chamá-la (2026-09-29)

Primeira aba da tela da paciente (`renderRevisao`, `#tab-revisao`). Feita para a
médica rever, na sala, tudo o que a paciente já fez — dela e de outros serviços —
antes de chamá-la. **A aba padrão ao abrir a paciente continua "Exames"**
(`setTab('exams')` em `openPatient`); mudar para "Revisão" é uma linha, se ela quiser.

- **Não calcula nada clínico novo.** Só junta o que o app já decide:
  `computeImpressaoDiagnostica` (diagnóstico, critérios, deterioração Doppler,
  conduta, notas, pré-eclâmpsia), `generateAlerts`, `avaliarTAPS`,
  `_discrepanciaPesoCardHtml`, `avaliarRiscoColoCurto`, `_bcfFora`. Uma regra
  clínica nova não entra aqui: entra na função de origem, e a revisão herda.
- **Três blocos:** Situação (IG hoje, DPP, tipo/corionicidade, G/P/A, último exame
  e há quantos dias, antecedentes/cerclagem/progesterona); "O que merece atenção";
  e a tabela de todos os exames, do mais recente ao mais antigo (PFE e CA com
  percentil, líquido, colo, BCF, AU, ACM/RCP, UtA, DV). Exame externo leva selo,
  serviço e a conclusão do laudo externo embaixo da linha. Na múltipla, uma linha
  por feto por visita.
- **Colo: vale o exame MAIS RECENTE que mediu, não o último exame.** O último pode
  ser um laudo externo sem colo, e o achado sumiria da revisão. Idem BCF.
  (`computeImpressaoDiagnostica` continua avaliando só o último exame, como antes.)
- **"Nenhum ponto de atenção" nunca vira "está tudo bem"**: o texto diz que vale só
  para o que foi cadastrado e que não substitui reler os laudos. Exame ausente é
  dado ausente, não normalidade (mesma regra do PIG constitucional).
- **Ainda não tem:** gráfico de tendência dentro da aba (os gráficos ficam na aba
  Gráficos), a lista "pacientes de hoje" (depende da agenda da Feegow) e o
  "o que medir hoje" — este último exigiria texto clínico novo, decisão dela.

## Conduta no app: só ultrassom — cadência de Doppler do serviço (2026-10-01)

A médica decidiu que o app **não traz conduta clínica**, só o que é do
ultrassom (qual exame, com que frequência). Estudamos o protocolo ISUOG 2020
(Lees et al.) inteiro para isso e as janelas de parto, corticoide, magnésio, via
de parto e indução dele **não entraram** — não reintroduzir por "completude".

- **Cadência (RCIU precoce e tardio, igual):** sem diástole zero/reversa →
  Doppler semanal; diástole ausente → 2×/semana; diástole reversa → 2×/dia;
  ducto venoso alterado (IP > P95 com onda A presente, ou onda A ausente/
  reversa) → diário ou 3×/semana. PIG: reavaliação semanal com Doppler enquanto
  o Doppler for normal. Isso substitui o "2–3×/semana" do achado leve, que
  constava como política dela. A ISUOG diz que não há consenso de frequência.
- **`redf_dv` foi dividido em `redf` e `dv_precoce`** (ordem de gravidade:
  leve < dv_precoce < aedf < redf < dv_tardio), porque as cadências diferem.
  AEDF com DV IP > P95 associado acrescenta a cadência do DV ao texto.
- **Vem da ISUOG só uma coisa de ultrassom:** alteração de ACM/RCP se confirma
  em nova medida em até 24 h (variabilidade interobservador).
- **Pendência:** os ramos GIG e "adequado" de `_condutaDiagnostico` e algumas
  notas ainda têm frases obstétricas; ela pediu "não colocar", não "tirar" —
  decidir se limpa.

## PIG exige PFE < P10; CA < P10 isolada vira nota (2026-10-03)

Decisão da médica: o consenso Delphi 2016 define CIUR, não PIG, e usa "CA/PFE"
como critério de crescimento. O **nome PIG**, porém, só sai com PFE < P10
(`efwBelowP10`, nos dois ramos de `calcDiagnosticoFGR`). CA < P10 com PFE ≥ P10
(`criterios.caIsoladaP10`, só quando há z de PFE) **não** nomeia PIG: o
diagnóstico fica `adequado`/`gig`, `_critItemsDiagnostico` diz "CA abaixo do P10,
com PFE adequada" (e por isso a Conclusão não afirma "trajetória estável") e
`_notasDiagnostico` pede reavaliar a CA. Dentro do CIUR a CA continua contando
como critério (Delphi puro): CA < P10 + uterinas > P95 antes de 32 semanas, ou
2 de 3 depois. O laudo obstétrico do editor (`laudos-dramorgana`)
já decidia PIG só pelo percentil de peso e não calcula CA: nenhum código mudou lá
(ver o `CLAUDE.md` dele); a única diferença é o critério CA + Doppler do CIUR.

## Filtros da busca: morfológico 1º/2º trimestre e gemelar (2026-10-03)

Três botões sob o campo de busca (`#filtro-chips`, `toggleFiltroBusca`,
`aplicarFiltrosBusca`). **O app não guarda o tipo do exame**, só a IG da visita:
"morfológico 1º tri" = exame entre 10 e 15 semanas (`_temExame1Tri`, a mesma
janela do Laudo 1º Trimestre e dos gráficos) e "2º tri" = entre 18 e 24
semanas (`_temExameMorfo2`) — é dedução, não rótulo. **Exame externo não conta.**
Os filtros combinam (E) entre si e com o texto digitado, e valem para a MESMA
gestação (`_gestacaoPassaFiltros`). Com filtro ativo, a lista de resultados
substitui "Pacientes Recentes" e Enter/Buscar só reaplica os filtros (não abre
a ficha). Só mostra quem JÁ fez; "ainda não fez, na janela" ficou de fora por
decisão dela.

## GIG é conceito de peso: só PFE > P90 (2026-10-06)

`calcDiagnosticoFGR` chamava GIG qualquer feto `adequado` com CA **ou** PFE > P90:
um feto no percentil 82 de peso saiu GIG só pela CA. Agora GIG exige `efwAboveP90`
(mesma regra do laudo obstétrico, que decide só pelo percentil de peso). CA > P90 com
PFE adequada não nomeia nada; fica só como critério em `_critItemsDiagnostico`
("CA acima do P90, com PFE adequada"), espelho da CA < P10 isolada do PIG.
