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

## Cuidado: salvamento no Supabase é assíncrono e não aguardado

`saveDB(db)` atualiza o estado local (`_memoryDB`) de forma síncrona, mas dispara
`_syncToSupabase(db)` sem `await` ("não aguardado de propósito", ver comentário no
código). Isso significa que um F5 ou navegação logo após cadastrar/editar algo pode
cancelar a requisição em andamento antes dela chegar ao servidor, perdendo o dado
silenciosamente (sem erro visível). Ver conversa de 2026-08-01 sobre pacientes de
teste que "sumiram" após reload — essa é a causa raiz, não um problema de branch.
