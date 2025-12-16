---
title: Trusted certificates for identity validation in TLS connections
layout: default
design_doc: true
revision: 1
status: draft
---

# Overview

In various use cases, TLS connections are established on the host on which XAPI runs.
When establishing a TLS connection, the peer identity needs to be validated.
This is done using either a root CA certificate to perform certificate chain validation, or a known peer certificate for validation with certificate pinning.
The root CA certificates and peer certificates involved in this process are referred to as trusted certificates.
When a trusted certificate is installed, the local endpoint can validate the peer identity during TLS connection establishment.
Certificate chain validation is a general-purpose, standards-based approach but requires additional steps, such as getting the peer's certificate signed by a CA.
In contrast, certificate pinning offers a quicker way to set up trust in some cases without the overhead of CA signing.
For example, in Trust‑On‑First‑Use (TOFU) policy and a self-signed server certificate scenario the first received leaf certificate can be trusted to avoid user intervention or configuration.

As the unified API for the whole system, XAPI also exposes interfaces for users to install and manage trusted certificates that are used by system components for different purposes.

The base design described in [pool-certificates.md](https://github.com/minglumlu/xen-api/blob/5d1ea1520825d502c57a90a02db476cd7d6a9132/doc/content/design/pool-certificates.md) defines the database, API, and trust store in the filesystem for managing trusted certificates.
This document introduces the following enhancements to that design:

* Explicit separation of root CA certificates and peer certificates:
In the base design, both certificate types share the same database schema, APIs, and are stored together in a single bundle file.
This makes it difficult to determine the appropriate validation approach based on the certificate type.
The improvement introduces a type value to separate root CA certificates and peer certificates explicitly.

* Add a "purpose" attribute for trusted certificates:
According to the base design, only certificates used for internal TLS connections among XAPI processes within a pool are stored separately.
All other trusted certificates are grouped in a single bundle, which may include certificates for multiple purposes.
By introducing a "purpose" attribute, certificates can be organized by their intended use, improving clarity and reducing ambiguity.

# Use Cases
* An XAPI client establishes a TLS connection to an XAPI service.
This case is outside the scope of trusted certificates managed by XAPI and is included here only for completeness.
* An XAPI process on one host initiates a TLS connection to an XAPI process on another host within the same pool.
This case is covered in the base design and is listed here for completeness.
* An XAPI process initiates a TLS connection to an external service, such as an appliance.
This case benefits from the improvements introduced in this design.
* A non-XAPI process (like licensing agent) running on a host managed by XAPI initiates a TLS connection to an external service, such as a License Server.
This case benefits from the improvements introduced in this design as well.


# Changes
## Database schema
The *Certificate* class in database is defined to represent general certificates, including trusted certificates.
One existing class field "type" supports the following enumeration values:
* "ca": trusted certificates including both root CA and peer.
* "host": identity certificate of a host for communication with entities outside the pool.
* "host_internal": identity certificate of a host for communication with other pool members.

Two improvements in this design:
* A new value "peer" is introduced in this design so that the existing "ca" now represents trusted root CA only.
The new "peer" will represent trusted peer certificates.

* A new enumeration type "purpose" is introduced to indicate the intended usage of a trusted certificate.
A new *Certificate* class field "purposes" (a set of values of enumeration type "purpose") will be added to represent all applicable purposes of a trusted certificate.
By default, this set is empty which corresponds to the existing general "ca" certificates for backwards compatibility.

## API

### pool.install_ca_certificate

This is an existing API to install a trusted certificate into the pool with its arguments being defined as:
* session (ref session_id): reference to a valid session;
* name (string): the name of the certificate;
* cert (string): the certificate in PEM format.

In this design, it is used to install root CA certificates only.
A new argument "purpose" is appended to specify the purposes of the trusted certificate to be installed. By default it is an empty set.
* session (ref session_id): reference to a valid session;
* name (string): the name of the certificate;
* cert (string): the certificate in PEM format;
* purpose (string list): the purposes of the certificate

### pool.install_peer_certificate
This is a new API introduced in this design with its arguments being defined as:
* session (ref session_id): reference to a valid session;
* name (string): the name of the certificate;
* cert (string): the certificate in PEM format;
* purpose (string list): the purposes of the certificate.

This new API can be used to install trusted peer certificates only.
The "purpose" parameter cannot be empty.

And corresponding "pool.uninstall_peer_certificate" for uninstalling a trusted peer certificate with arguments:
* session (ref session_id): reference to a valid session;
* name (string): the name of the certificate;
* force (bool): remove the database entry even if the file doesn't exist.

### pool.join
Since the trusted certificates managed in this design are pool-wide, any existing trusted certificates on the joining host should be removed during pool.join.
Instead, all trusted certificates from the pool will be synchronized to the new host in the pre-join phase.

### Other APIs
The install/uninstall APIs above are not the only ways of managing the trusted certificates.
A particular API, e.g. "pool.set_wlb_url", may also install the trusted certificate used to validate the WLB server on subsequent TLS connections.
However, regardless of the entry point, all trusted certificates must be represented by a *Certificate* database object and stored in the same way described below as if installed by the install APIs.

## Trust store
The trusted certificates are stored in individual hosts' filesystems.
The existing stores defined in the base design are:
| Name | Filesystem location | User-configurable | Used for |
| ---- | ------------------- | ----------------- | -------- |
| Trusted Default | /etc/stunnel/certs/              | yes (using API) | Certificates that users can install for trusting appliances
| Trusted Pool    | /etc/stunnel/certs-pool/         | no              | Certificates that are managed by the pool for host-to-host communications
| Default Bundle  | /etc/stunnel/xapi-stunnel-ca-bundle.pem | no       | Bundle of certificates that hosts use to verify appliances (in particular WLB), this is kept in sync with "Trusted Default"
| Pool Bundle     | /etc/stunnel/xapi-pool-ca-bundle.pem    | no       | Bundle of certificates that hosts use to verify other hosts on pool communications, this is kept in sync with "Trusted Pool"

Regarding the "User-configurable", when it is "yes", it means a user can only install and remove the file via APIs; when it is "no", it means the user can't install or remove it even via APIs. In any cases, a user can't change the certificate files directly.

When a trusted certificate is being installed via "pool.install_ca_certificate" but with an empty "purpose",
the trusted certificate will be stored in the existing "Trusted Default" and "Default Bundle" for general purpose.

There is no general‑purpose store for trusted peer certificates, because each peer certificate is specific to a single server and therefore unsuitable for a shared trust bundle for general purpose.

The pool "Trusted Pool" and "Pool Bundle" are for host-to-host TLS communications within a pool. This design doesn't change them.


When the "purpose" is not empty, the stores for the certificates installed via "pool.install_ca_certificate" or "pool.install_peer_certificate" are defined as:
| Name | Filesystem location | User-configurable | Used for |
| ---- | ------------------- | ----------------- | -------- |
| Trusted Peer | /etc/trusted-certs/peer-\<PURPOSE\>/     | yes (using API) | Trusted peer certificates that users can install to validate a peer’s identity when establishing a TLS connection for \<PURPOSE\>
| Trusted CA | /etc/trusted-certs/ca-\<PURPOSE\>/         | yes (using API) | Trusted root CA certificates that users can install to validate a peer’s identity when establishing a TLS connection for \<PURPOSE\>
| Peer Bundle  | /etc/trusted-certs/peer-bundle-\<PURPOSE\>.pem | no | Bundle of trusted peer certificates under /etc/trusted-certs/peer-\<PURPOSE\>/ to verify a peer's identity when establishing a TLS connection for \<PURPOSE\>
| CA Bundle     | /etc/trusted-certs/ca-bundle-\<PURPOSE\>.pem  | no | Bundle of trusted root CA certificates under /etc/trusted-certs/ca-\<PURPOSE\>/ to verify a peer's identity when establishing a TLS connection for \<PURPOSE\>

The filesystem location is derived from the \<PURPOSE\>. Each \<PURPOSE\> string corresponds to a predefined value of the "purpose" type in the database, implemented as predefined constants.

## Precedence order of choosing trust stores
The "Peer Bundle", "CA Bundle", and "Default Bundle" can be directly used when establishing TLS connections.
The endpoint to validate the peer's identity must unambiguously choose only one from these bundles with the following precedence order:
1. "Peer Bundle"
2. "CA Bundle"
3. "Default Bundle"

For example, if "Peer Bundle" exists for the particular purpose, use this bundle file and certificate pinning to validate the peer's identity.
No more attempts with "CA Bundle" or "Default Bundle" even when the validation with "Peer Bundle" failed.
