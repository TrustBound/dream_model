insert into events (id, kind, payload) values ($1, $2, $3)
returning id
