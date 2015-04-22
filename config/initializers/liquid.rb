{
    eval: Cenit::Eval,
    base64: Cenit::Base64,
    scape_b64: Cenit::ScapeB64
}.each { |key, klass| Liquid::Template.register_tag(key, klass) }