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
