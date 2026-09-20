def to_cloudflared_ingress(registry, external_domain, cloudflared_default_origin):
    """Baut aus service_registry-Einträgen mit upstream und exposure die Cloudflared-Ingress-Form."""
    result = []
    for item in registry:
        if item.get('exposure') != 'tunnel':
            continue
        result.append({
            'hostname': item['name'] + "." + external_domain,
            'service': cloudflared_default_origin + ":443",
        })
    return result

class FilterModule:
    def filters(self):
        return {'to_cloudflared_ingress': to_cloudflared_ingress}
