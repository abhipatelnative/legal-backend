-- Add inventory permission
INSERT INTO permissions (name, description, resource_type, created_at, updated_at) 
VALUES ('inventory', 'Access to inventory and purchase management', 'inventory', NOW(), NOW())
ON CONFLICT (name) DO NOTHING;

-- Grant inventory permission to Admin role
INSERT INTO role_permissions (role_id, permission_id, created_at, updated_at)
SELECT r.id, p.id, NOW(), NOW()
FROM roles r, permissions p
WHERE r.name = 'Admin' AND p.name = 'inventory'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Grant inventory permission to HR Manager role
INSERT INTO role_permissions (role_id, permission_id, created_at, updated_at)
SELECT r.id, p.id, NOW(), NOW()
FROM roles r, permissions p
WHERE r.name = 'HR Manager' AND p.name = 'inventory'
ON CONFLICT (role_id, permission_id) DO NOTHING;