import { createBackendModule } from '@backstage/backend-plugin-api';
import {
  AuthorizeResult,
  isResourcePermission,
  type PolicyDecision,
} from '@backstage/plugin-permission-common';
import type {
  PermissionPolicy,
  PolicyQuery,
} from '@backstage/plugin-permission-node';
import { policyExtensionPoint } from '@backstage/plugin-permission-node/alpha';
import {
  createScaffolderActionConditionalDecision,
  scaffolderActionConditions,
} from '@backstage/plugin-scaffolder-backend/alpha';
import { RESOURCE_TYPE_SCAFFOLDER_ACTION } from '@backstage/plugin-scaffolder-common/alpha';

export class ForgePathPermissionPolicy implements PermissionPolicy {
  async handle(request: PolicyQuery): Promise<PolicyDecision> {
    if (request.permission.name === 'kubernetes.proxy') {
      return { result: AuthorizeResult.DENY };
    }
    if (
      isResourcePermission(
        request.permission,
        RESOURCE_TYPE_SCAFFOLDER_ACTION,
      )
    ) {
      return createScaffolderActionConditionalDecision(
        request.permission,
        scaffolderActionConditions.hasActionId({
          actionId: 'forgepath:renderSecureFastapi',
        }),
      );
    }
    return { result: AuthorizeResult.ALLOW };
  }
}

export default createBackendModule({
  pluginId: 'permission',
  moduleId: 'forgepath-read-only-kubernetes',
  register(registration) {
    registration.registerInit({
      deps: { policy: policyExtensionPoint },
      async init({ policy }) {
        policy.setPolicy(new ForgePathPermissionPolicy());
      },
    });
  },
});
