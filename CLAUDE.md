# curva-fetal

Site estático de página única, sem build step.

## Branch publicada pelo GitHub Pages — IMPORTANTE

O GitHub Pages **não publica a partir da `main`**. A branch de origem configurada é
`claude/fetal-clinic-security-audit-c4ajnl`, e o arquivo servido é `index.html`
(na raiz do repo, nessa branch). Antes de assumir que "main = produção", confirme
a branch de origem real olhando os runs do workflow "pages build and deployment"
(`head_branch` dos runs mais recentes) — não confie apenas no nome do branch padrão.

A `main` está desatualizada em relação a `claude/fetal-clinic-security-audit-c4ajnl`:
esta última tem login/Supabase, backup manual, importação e outras correções que a
`main` não tem. Os dois arquivos também têm nomes diferentes (`Curvas de Crescimento
Fetal.html` na main vs `index.html` na branch do Pages). Não faça merge cego entre
elas — aplique correções pontuais direto na branch que o Pages publica quando o
objetivo é atualizar o site ao vivo.

## Fluxo de deploy

Depois de validar uma mudança, faça merge/push direto para a branch que o Pages
publica (confirme qual é, ver acima) sem pedir confirmação a cada vez — esse é o
comportamento combinado com o usuário. O Pages atualiza em ~1 minuto após o push.
