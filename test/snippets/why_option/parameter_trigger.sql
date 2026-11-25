insert into users (id, email, nickname) values ($1, $2, $3)
returning id
