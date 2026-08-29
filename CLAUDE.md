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
- **Lixeira:** `excluido_em` preenchido significa fora de toda leitura normal. As
  buscas do editor filtram `.is('excluido_em', null)` pelo mesmo motivo, e o
  unique da 004 é parcial (`where excluido_em is null`) para não impedir o
  recadastro de um CPF que foi para a lixeira.
