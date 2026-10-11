%% OTP-only X.509 primitives for `loom distribution provision` and `install`,
%% reached only through client/internal/ffi_pki.gleam. No Gleam package builds
%% or signs a certificate, and the operator is not asked to install openssl, so
%% the minting goes through OTP's public_key and crypto applications.
%%
%% The surface is deliberately small: mint a certificate authority, issue a
%% node certificate under it, take the SHA-256 of a certificate's DER (the pin
%% a peer row carries), inspect a node's credentials before they are installed,
%% and draw random bytes for the cookie. Plan logic, validation and file layout
%% stay in Gleam.
%%
%% Every key is an ECDSA P-256 key and every signature is ecdsa-with-SHA256.
%% The authority and node validity periods are fixed below; renewing them is
%% certificate rotation, which is later work.
-module(client_pki_ffi).
-export([authority/1, issue/4, pin/1, inspect/3, random_bytes/1]).
-include_lib("public_key/include/public_key.hrl").

-define(CURVE, secp256r1).
-define(AUTHORITY_DAYS, 3650).
-define(NODE_DAYS, 1825).

%% A self-signed authority. It signs node certificates during provisioning and
%% its key is then dropped, so nothing the operator keeps can mint a node.
authority(CommonName) ->
    Key = public_key:generate_key({namedCurve, ?CURVE}),
    Subject = subject(CommonName),
    Extensions = [
        #'Extension'{extnID = ?'id-ce-keyUsage',
                     extnValue = [keyCertSign, cRLSign], critical = false},
        #'Extension'{extnID = ?'id-ce-basicConstraints',
                     extnValue = #'BasicConstraints'{cA = true}, critical = true}],
    Der = sign(Subject, Subject, Key, Key, Extensions, ?AUTHORITY_DAYS),
    {pem_certificate(Der), pem_key(Key)}.

%% A node certificate under the authority. `Names` are the DNS names it
%% carries: the exact Erlang node name, which the verify callback compares, and
%% the host, which the TLS host name check compares. A name that is an IP
%% literal also becomes an iPAddress entry, because the host name check of an
%% IP address looks there.
issue(CaPem, CaKeyPem, CommonName, Names) ->
    try
        [{'Certificate', CaDer, not_encrypted}] = public_key:pem_decode(CaPem),
        CaKey = decode_key(CaKeyPem),
        #'OTPCertificate'{tbsCertificate = CaTbs} =
            public_key:pkix_decode_cert(CaDer, otp),
        Issuer = CaTbs#'OTPTBSCertificate'.subject,
        Key = public_key:generate_key({namedCurve, ?CURVE}),
        Extensions = [
            #'Extension'{extnID = ?'id-ce-keyUsage',
                         extnValue = [digitalSignature, keyAgreement],
                         critical = false},
            #'Extension'{extnID = ?'id-ce-subjectAltName',
                         extnValue = alternative_names(Names), critical = false}],
        Der = sign(Issuer, subject(CommonName), CaKey, Key, Extensions, ?NODE_DAYS),
        {ok, {pem_certificate(Der), pem_key(Key)}}
    catch _:_ -> {error, nil}
    end.

%% The SHA-256 of the DER of the first certificate in a PEM, which is the pin a
%% peer row carries and the verify callback compares.
pin(CertPem) ->
    try
        [{'Certificate', Der, not_encrypted} | _] = public_key:pem_decode(CertPem),
        {ok, crypto:hash(sha256, Der)}
    catch _:_ -> {error, nil}
    end.

%% Checks that a node's three PEMs are readable, that the certificate chains to
%% the authority and is within its validity period, and that the key is the
%% certificate's own. On success it returns the DNS names the certificate
%% carries so the caller can compare the node name.
inspect(CaPem, CertPem, KeyPem) ->
    try
        case inspect_credentials(CaPem, CertPem, KeyPem) of
            {error, _} = Refusal -> Refusal;
            Names -> {ok, Names}
        end
    catch _:_ -> {error, unreadable}
    end.

inspect_credentials(CaPem, CertPem, KeyPem) ->
    case {decode_certificate(CaPem), decode_certificate(CertPem), decode_key_safe(KeyPem)} of
        {error, _, _} -> {error, unreadable_authority};
        {_, error, _} -> {error, unreadable_certificate};
        {_, _, error} -> {error, unreadable_key};
        {{ok, CaDer}, {ok, Der}, {ok, Key}} ->
            case public_key:pkix_path_validation(CaDer, [Der], []) of
                {ok, _} ->
                    Otp = public_key:pkix_decode_cert(Der, otp),
                    #'OTPCertificate'{tbsCertificate = Tbs} = Otp,
                    Spki = Tbs#'OTPTBSCertificate'.subjectPublicKeyInfo,
                    case same_key(Key, Spki#'OTPSubjectPublicKeyInfo'.subjectPublicKey) of
                        true -> dns_names(Tbs);
                        false -> {error, key_mismatch}
                    end;
                {error, _} -> {error, chain_rejected}
            end
    end.

random_bytes(Count) -> crypto:strong_rand_bytes(Count).

%% ------------------------------------------------------------------ internal

subject(CommonName) ->
    {rdnSequence, [[#'AttributeTypeAndValue'{
        type = ?'id-at-commonName', value = {utf8String, CommonName}}]]}.

alternative_names(Names) ->
    lists:flatmap(fun(Name) ->
        Text = binary_to_list(Name),
        case inet:parse_address(Text) of
            {ok, Address} -> [{dNSName, Text}, {iPAddress, address_bytes(Address)}];
            {error, _} -> [{dNSName, Text}]
        end
    end, Names).

address_bytes({A, B, C, D}) -> <<A, B, C, D>>;
address_bytes({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>.

%% A certificate signed by `SignerKey` that certifies the public half of
%% `SubjectKey`. The serial number is random, so two runs never collide, and
%% the validity begins a day in the past to tolerate clock skew between hosts.
sign(Issuer, Subject, SignerKey, SubjectKey, Extensions, Days) ->
    Today = calendar:date_to_gregorian_days(date()),
    Tbs = #'OTPTBSCertificate'{
        version = v3,
        serialNumber = binary:decode_unsigned(crypto:strong_rand_bytes(8)) bsr 1,
        signature = #'SignatureAlgorithm'{
            algorithm = ?'ecdsa-with-SHA256', parameters = asn1_NOVALUE},
        issuer = Issuer,
        validity = #'Validity'{
            notBefore = utc(calendar:gregorian_days_to_date(Today - 1)),
            notAfter = utc(calendar:gregorian_days_to_date(Today + Days))},
        subject = Subject,
        subjectPublicKeyInfo = #'OTPSubjectPublicKeyInfo'{
            algorithm = #'PublicKeyAlgorithm'{
                algorithm = ?'id-ecPublicKey',
                parameters = SubjectKey#'ECPrivateKey'.parameters},
            subjectPublicKey = #'ECPoint'{point = SubjectKey#'ECPrivateKey'.publicKey}},
        issuerUniqueID = asn1_NOVALUE,
        subjectUniqueID = asn1_NOVALUE,
        extensions = Extensions},
    public_key:pkix_sign(Tbs, SignerKey).

%% Dates before 2050 are UTCTime and later ones GeneralizedTime (RFC 5280).
utc({Year, Month, Day}) when Year < 2050 ->
    {utcTime, lists:flatten(io_lib:format("~2..0w~2..0w~2..0w000000Z",
                                          [Year rem 100, Month, Day]))};
utc({Year, Month, Day}) ->
    {generalTime, lists:flatten(io_lib:format("~4..0w~2..0w~2..0w000000Z",
                                              [Year, Month, Day]))}.

pem_certificate(Der) ->
    public_key:pem_encode([{'Certificate', Der, not_encrypted}]).

pem_key(Key) ->
    public_key:pem_encode([public_key:pem_entry_encode('ECPrivateKey', Key)]).

decode_key(Pem) ->
    [Entry] = public_key:pem_decode(Pem),
    public_key:pem_entry_decode(Entry).

decode_key_safe(Pem) ->
    try {ok, decode_key(Pem)} catch _:_ -> error end.

decode_certificate(Pem) ->
    try
        [{'Certificate', Der, not_encrypted}] = public_key:pem_decode(Pem),
        _ = public_key:pkix_decode_cert(Der, otp),
        {ok, Der}
    catch _:_ -> error
    end.

same_key(#'ECPrivateKey'{publicKey = Point}, #'ECPoint'{point = Point}) -> true;
same_key(#'RSAPrivateKey'{modulus = N, publicExponent = E},
         #'RSAPublicKey'{modulus = N, publicExponent = E}) -> true;
same_key(_, _) -> false.

dns_names(#'OTPTBSCertificate'{extensions = Extensions}) ->
    case lists:keyfind(?'id-ce-subjectAltName', #'Extension'.extnID,
                       extension_list(Extensions)) of
        #'Extension'{extnValue = Names} ->
            [unicode:characters_to_binary(Dns) || {dNSName, Dns} <- Names];
        false -> []
    end.

extension_list(asn1_NOVALUE) -> [];
extension_list(Extensions) -> Extensions.
