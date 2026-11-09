-- Ejecutar DESPUÉS de 1-base.sql (Supabase > SQL Editor > Run)

-- Existencias apartadas (congeladas)
alter table product_sizes add column reserved int not null default 0 check (reserved >= 0);
alter table product_sizes add constraint chk_reserved_le_stock check (reserved <= stock);

create table customers(
  id uuid primary key default gen_random_uuid(),
  cedula text unique not null,
  name text not null,
  phone text,
  type text not null default 'detal' check (type in ('detal','dist','mayor')),
  created_at timestamptz default now()
);
create table reservations(
  id uuid primary key default gen_random_uuid(),
  n bigint generated always as identity,
  customer_id uuid not null references customers(id),
  status text not null default 'activo' check (status in ('activo','vendido','cancelado')),
  total int not null default 0,
  created_at timestamptz default now(),
  closed_at timestamptz
);
create table reservation_items(
  id bigint generated always as identity primary key,
  reservation_id uuid not null references reservations(id) on delete cascade,
  product_id text not null,
  product_name text,
  size text not null,
  qty int not null check (qty > 0),
  unit_price int not null
);
alter table customers enable row level security;
alter table reservations enable row level security;
alter table reservation_items enable row level security;
create policy "admin clientes" on customers for all to authenticated using (true) with check (true);
create policy "admin apartados" on reservations for all to authenticated using (true) with check (true);
create policy "admin items" on reservation_items for all to authenticated using (true) with check (true);

-- La tablet consulta SOLO nombre y tipo, nunca la lista de clientes
create or replace function lookup_customer(p_ced text) returns json
language sql security definer set search_path = public as $$
  select json_build_object('name', name, 'type', type)
  from customers where cedula = regexp_replace(p_ced,'\D','','g') limit 1
$$;

create or replace function registrar_cliente(p_ced text, p_name text, p_phone text) returns json
language plpgsql security definer set search_path = public as $$
declare c customers; d text := regexp_replace(p_ced,'\D','','g');
begin
  if length(d) < 5 or length(trim(coalesce(p_name,''))) < 2 then raise exception 'Datos incompletos'; end if;
  insert into customers(cedula,name,phone,type) values (d, trim(p_name), trim(p_phone), 'detal')
  on conflict (cedula) do nothing;
  select * into c from customers where cedula = d;
  return json_build_object('name', c.name, 'type', c.type);
end $$;

-- Apartar: congela unidades. El precio lo calcula el servidor según el tipo de cliente.
create or replace function apartar(p_ced text, p_items jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare c customers; r reservations; it jsonb; pr products; ps product_sizes;
        v_price int; v_total int := 0; q int;
begin
  select * into c from customers where cedula = regexp_replace(p_ced,'\D','','g');
  if not found then raise exception 'Cliente no registrado'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) = 0 then raise exception 'Pedido vacío'; end if;
  insert into reservations(customer_id,status,total) values (c.id,'activo',0) returning * into r;
  for it in select value from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::int;
    if q <= 0 then raise exception 'Cantidad inválida'; end if;
    select * into pr from products where id = it->>'product_id' and active;
    if not found then raise exception 'Producto no disponible: %', it->>'product_id'; end if;
    select * into ps from product_sizes where product_id = pr.id and size = it->>'size' for update;
    if not found or ps.stock - ps.reserved < q then
      raise exception 'Sin existencias suficientes: % talla %', pr.id, it->>'size';
    end if;
    update product_sizes set reserved = reserved + q where product_id = pr.id and size = ps.size;
    v_price := case c.type when 'mayor' then pr.price_mayor when 'dist' then pr.price_dist else pr.price_detal end;
    insert into reservation_items(reservation_id,product_id,product_name,size,qty,unit_price)
      values (r.id, pr.id, pr.name, ps.size, q, v_price);
    v_total := v_total + v_price * q;
  end loop;
  update reservations set total = v_total where id = r.id;
  return json_build_object('n', r.n, 'total', v_total);
end $$;

-- Venta final: resta del stock y libera el congelado
create or replace function vender_apartado(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare r reservations; it reservation_items;
begin
  select * into r from reservations where id = p_id for update;
  if not found or r.status <> 'activo' then raise exception 'El apartado no está activo'; end if;
  for it in select * from reservation_items where reservation_id = p_id loop
    update product_sizes set stock = stock - it.qty, reserved = reserved - it.qty
      where product_id = it.product_id and size = it.size;
  end loop;
  update reservations set status = 'vendido', closed_at = now() where id = p_id;
  return json_build_object('n', r.n, 'total', r.total);
end $$;

create or replace function liberar_apartado(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare r reservations; it reservation_items;
begin
  select * into r from reservations where id = p_id for update;
  if not found or r.status <> 'activo' then raise exception 'El apartado no está activo'; end if;
  for it in select * from reservation_items where reservation_id = p_id loop
    update product_sizes set reserved = reserved - it.qty where product_id = it.product_id and size = it.size;
  end loop;
  update reservations set status = 'cancelado', closed_at = now() where id = p_id;
  return json_build_object('n', r.n);
end $$;

create or replace function vender_directo(p_ced text, p_items jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare a json;
begin
  a := apartar(p_ced, p_items);
  return vender_apartado((select id from reservations where n = (a->>'n')::bigint));
end $$;

-- Solo el administrador (con sesión) puede vender o liberar
revoke execute on function vender_apartado(uuid), liberar_apartado(uuid), vender_directo(text,jsonb) from public, anon;
grant execute on function vender_apartado(uuid), liberar_apartado(uuid), vender_directo(text,jsonb) to authenticated;

-- Cliente de prueba (bórralo después): cédula 1000000001, mayorista
insert into customers(cedula,name,phone,type) values ('1000000001','Cliente Mayorista Demo','3000000000','mayor');
