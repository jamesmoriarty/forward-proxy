# CHANGELOG

## 0.1.4

- `accept` connections via thread pool.
- catch and throw custom http parse error.
- `Server:` header added for default error 502 response.
- rescue and logs socket error `Errno::EBADF`.

## 0.1.3

- Refine CLI help text.

## 0.1.2

- Wrap ThreadPool in ForwardProxy module.