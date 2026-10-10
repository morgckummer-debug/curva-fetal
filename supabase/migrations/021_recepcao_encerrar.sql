-- 021: encerrar o acompanhamento (parto, perda gestacional, desistência).
-- A gestação sai da lista da recepção (que só mostra status 'ativa'). Nova opção de status:
-- 'desistencia'. A médica reabre pela ficha (Editar gestação → Status → Ativa).
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'public.gestacoes'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) like '%obito_fetal%';
  if c is not null then execute format('alter table public.gestacoes drop constraint %I', c); end if;
  alter table public.gestacoes add constraint gestacoes_status_check
    check (status in ('ativa','finalizada','aborto','ectopica','obito_fetal','desistencia'));
end $$;

create or replace function public.recepcao_encerrar(p_gestacao_id bigint, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_status text;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  v_status := case p_motivo
    when 'parto' then 'finalizada'
    when 'perda' then 'aborto'
    when 'obito' then 'obito_fetal'
    when 'desistencia' then 'desistencia'
    else null end;
  if v_status is null then raise exception 'motivo inválido'; end if;
  if not exists (select 1 from public.gestacoes
                  where id = p_gestacao_id and user_id = v_dono and excluido_em is null and status = 'ativa') then
    raise exception 'gestação ativa não encontrada';
  end if;
  update public.gestacoes set status = v_status where id = p_gestacao_id;
end;
$$;

revoke all on function public.recepcao_encerrar(bigint, text) from public, anon;
grant execute on function public.recepcao_encerrar(bigint, text) to authenticated;
