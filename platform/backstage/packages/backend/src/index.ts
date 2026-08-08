import { createBackend } from '@backstage/backend-defaults';
import forgePathScaffolderModule from './modules/forgePathScaffolder';
import forgePathPermissionModule from './modules/forgePathPermissions';

const backend = createBackend();

backend.add(import('@backstage/plugin-app-backend'));
backend.add(import('@backstage/plugin-auth-backend'));
backend.add(import('@backstage/plugin-auth-backend-module-guest-provider'));
backend.add(import('@backstage/plugin-catalog-backend'));
backend.add(
  import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'),
);
backend.add(import('@backstage/plugin-kubernetes-backend'));
backend.add(import('@backstage/plugin-permission-backend'));
backend.add(import('@backstage/plugin-proxy-backend'));
backend.add(import('@backstage/plugin-scaffolder-backend'));
backend.add(import('@backstage/plugin-techdocs-backend'));
backend.add(forgePathScaffolderModule);
backend.add(forgePathPermissionModule);

backend.start();
