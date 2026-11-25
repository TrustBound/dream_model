select email, count(*) as total
from users group by rollup (email)
