def to_gatus_endpoints(registry, host, failure_threshold):
    """Baut aus service_registry-Einträgen mit health_url die Gatus-Endpoint-Form."""
    result = []
    for item in registry:
        if 'health_url' not in item:
            continue
        if item.get('gatus_host', 'lxc-gatus') != host:
            continue
        result.append({
            'name': item.get('gatus_name', item['name']),
            'group': item.get('gatus_group', 'services'),
            'url': item['health_url'],
            'interval': '1m',
            'conditions': item.get('gatus_conditions', ['[STATUS] == 200']),
            'alerts': [{
                'type': 'discord',
                'failure-threshold': failure_threshold,
                'send-on-resolved': True,
            }],
        })
    return result


class FilterModule:
    def filters(self):
        return {'to_gatus_endpoints': to_gatus_endpoints}
