# Connecting to a server

When Goguma is launched for the first time, it asks for a server, nickname and
(optionally) a password.

The server field accepts hostnames, such as "irc.libera.chat". This should
cover most use-cases. Also supported are:

- IPv4 and IPv6 addresses.
- `<host>:<port>`, for servers using non-standard ports.
- `irc+insecure://<host>:<port>`, for insecure cleartext connections. Warning,
  only use for local development.

Once the server field is filled in, Goguma will query the server capabilities.
Some servers don't support SASL authentication, in which case the password
field will get hidden. Some servers require SASL authentication, in which case
the password field won't be optional anymore.
