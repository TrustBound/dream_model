-- returns: maybe
update posts set published = true where id = $1 returning published
