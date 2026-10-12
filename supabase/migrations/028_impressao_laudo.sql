-- 028: conclusão (impressão diagnóstica) do laudo do editor, guardada no exame.
-- O editor de laudos grava o texto final (com as edições da médica); o Curvas mostra
-- na aba Revisão. Aditiva: nada existente muda.
alter table public.exams add column if not exists impressao_laudo text;
