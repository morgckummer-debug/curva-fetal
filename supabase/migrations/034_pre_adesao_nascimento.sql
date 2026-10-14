-- 034 — Pré-adesão: a paciente também informa a data de nascimento (vai para o contrato).
-- Recria vitrine_pre_adesao com p_nascimento (opcional, para a página antiga em cache continuar
-- funcionando). recepcao_pre_adesoes devolve a coluna sozinha (to_jsonb da linha).

alter table public.pre_adesoes add column if not exists nascimento date;

drop function if exists public.vitrine_pre_adesao(text, text, text, text, text, text, date, date, int, text);

create or replace function public.vitrine_pre_adesao(
  p_chave text, p_nome text, p_cpf text, p_email text, p_celular text, p_modalidade text,
  p_dum date default null, p_us_data date default null, p_us_ig_dias int default null,
  p_origem text default 'ipad', p_nascimento date default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_dig  text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_cpf  text;
  v_nome text := regexp_replace(btrim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  v_id   bigint;
begin
  if p_chave is null or length(p_chave) < 32 then raise exception 'chave inválida'; end if;
  select dono_id into v_dono from public.vitrine_chaves where token = p_chave;
  if v_dono is null then raise exception 'chave inválida'; end if;
  if length(v_nome) < 5 or length(v_nome) > 120 or position(' ' in v_nome) = 0 then raise exception 'informe o nome completo'; end if;
  if length(v_dig) <> 11 then raise exception 'CPF deve ter 11 dígitos'; end if;
  if p_modalidade not in ('essencial','premium','gemelar_essencial','gemelar_dc') then raise exception 'modalidade inválida'; end if;
  if p_dum is not null and (p_dum > current_date or p_dum < current_date - 300) then raise exception 'DUM inválida'; end if;
  if p_nascimento is not null and (p_nascimento > current_date - interval '10 years' or p_nascimento < current_date - interval '60 years') then raise exception 'data de nascimento inválida'; end if;
  if p_us_data is not null and (p_us_data > current_date or p_us_data < current_date - 300) then raise exception 'data do ultrassom inválida'; end if;
  -- Freio contra abuso da página pública: no máximo 30 pré-adesões novas por dia.
  if (select count(*) from public.pre_adesoes where dono_id = v_dono and criado_em > now() - interval '1 day') >= 30 then
    raise exception 'limite diário atingido; procure a recepção';
  end if;
  v_cpf := substr(v_dig,1,3) || '.' || substr(v_dig,4,3) || '.' || substr(v_dig,7,3) || '-' || substr(v_dig,10,2);
  select id into v_id from public.pre_adesoes where dono_id = v_dono and cpf = v_cpf and status = 'nova';
  if v_id is not null then
    update public.pre_adesoes
       set nome = v_nome, email = left(btrim(coalesce(p_email, '')), 120), celular = left(btrim(coalesce(p_celular, '')), 20),
           modalidade = p_modalidade, dum = p_dum, us_data = p_us_data,
           us_ig_dias = case when p_us_data is not null then p_us_ig_dias end, criado_em = now(),
           origem = case when p_origem = 'link' then 'link' else 'ipad' end, nascimento = p_nascimento
     where id = v_id;
  else
    insert into public.pre_adesoes (dono_id, nome, cpf, email, celular, modalidade, dum, us_data, us_ig_dias, origem, nascimento)
    values (v_dono, v_nome, v_cpf, left(btrim(coalesce(p_email, '')), 120), left(btrim(coalesce(p_celular, '')), 20),
            p_modalidade, p_dum, p_us_data, case when p_us_data is not null then p_us_ig_dias end,
            case when p_origem = 'link' then 'link' else 'ipad' end, p_nascimento);
  end if;
  return true;
end;
$$;

revoke all on function public.vitrine_pre_adesao(text, text, text, text, text, text, date, date, int, text, date) from public;
grant execute on function public.vitrine_pre_adesao(text, text, text, text, text, text, date, date, int, text, date) to anon, authenticated;
