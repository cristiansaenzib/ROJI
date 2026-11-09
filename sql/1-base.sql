-- Pega todo esto en Supabase > SQL Editor > Run

create table products(
  id text primary key,
  type text not null,
  name text not null,
  color text default '#cccccc',
  accent text default '#1f5f4a',
  price_detal int not null default 0,
  price_dist int not null default 0,
  price_mayor int not null default 0,
  img_front text,
  img_back text,
  active boolean not null default true,
  created_at timestamptz default now()
);
create table product_sizes(
  product_id text references products(id) on delete cascade,
  size text,
  stock int not null default 0 check (stock >= 0),
  sort int default 0,
  primary key (product_id, size)
);

alter table products enable row level security;
alter table product_sizes enable row level security;
-- Cualquiera puede VER el catálogo
create policy "ver productos" on products for select using (true);
create policy "ver tallas" on product_sizes for select using (true);
-- Solo el administrador (con sesión) puede modificar
create policy "admin productos" on products for all to authenticated using (true) with check (true);
create policy "admin tallas" on product_sizes for all to authenticated using (true) with check (true);

-- Actualización en vivo del catálogo
alter publication supabase_realtime add table products, product_sizes;

-- Fotos
insert into storage.buckets (id, name, public) values ('productos','productos',true) on conflict do nothing;
create policy "ver fotos" on storage.objects for select using (bucket_id = 'productos');
create policy "admin sube fotos" on storage.objects for insert to authenticated with check (bucket_id = 'productos');
create policy "admin edita fotos" on storage.objects for update to authenticated using (bucket_id = 'productos');
create policy "admin borra fotos" on storage.objects for delete to authenticated using (bucket_id = 'productos');

-- Productos de ejemplo (puedes borrarlos desde el admin)
insert into products (id,type,name,color,accent,price_detal,price_dist,price_mayor) values
 ('CAM-101','Camisetas','Camiseta básica Blanca','#f4f4f4','#1f5f4a',35000,28000,24000),
 ('CHA-201','Chaquetas','Chaqueta bomber Verde','#3f6b4f','#e8c547',135000,112000,98000),
 ('PAN-301','Pantalones','Jean clásico Azul medio','#3b5b8c','#e8c547',98000,82000,74000);
insert into product_sizes (product_id,size,stock,sort) values
 ('CAM-101','S',6,0),('CAM-101','M',12,1),('CAM-101','L',10,2),('CAM-101','XL',4,3),
 ('CHA-201','S',2,0),('CHA-201','M',6,1),('CHA-201','L',6,2),('CHA-201','XL',3,3),
 ('PAN-301','28',3,0),('PAN-301','30',6,1),('PAN-301','32',8,2),('PAN-301','34',5,3),('PAN-301','36',2,4);
