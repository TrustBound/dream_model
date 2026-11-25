-- The schema of the end-to-end app. The tests run it in a new database on
-- each PostgreSQL version before they generate the models.
create extension citext;

create type mood as enum ('happy', 'sad');

create domain positive_int as int check (value > 0);

create table users (
  id bigserial primary key,
  email citext not null unique,
  nickname text,
  created_at timestamptz not null default now()
);

create table posts (
  id serial primary key,
  user_id bigint not null references users (id),
  title varchar(200) not null,
  body text,
  published boolean not null default false
);

create table samples (
  id serial primary key,
  small smallint,
  big bigint,
  object oid,
  real_number real,
  double_number double precision,
  amount numeric,
  label varchar(20),
  code char(3),
  short_name name,
  nickname citext,
  document json,
  binary_document jsonb,
  feeling mood,
  flag boolean,
  data bytea,
  identifier uuid,
  happened_at timestamp,
  happened_at_zone timestamptz,
  day date,
  clock time,
  tags text[],
  scores int[],
  rating positive_int
);

create unique index samples_label_index on samples (label);
