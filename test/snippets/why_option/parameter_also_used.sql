update users set nickname = $1 where nickname = $1
returning id
