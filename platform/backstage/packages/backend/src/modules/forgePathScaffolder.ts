import {
  coreServices,
  createBackendModule,
} from '@backstage/backend-plugin-api';
import { scaffolderActionsExtensionPoint } from '@backstage/plugin-scaffolder-node';
import { createRenderSecureFastapiAction } from '../actions/renderSecureFastapi';

export default createBackendModule({
  pluginId: 'scaffolder',
  moduleId: 'forgepath-local-renderer',
  register(registration) {
    registration.registerInit({
      deps: {
        config: coreServices.rootConfig,
        scaffolder: scaffolderActionsExtensionPoint,
      },
      async init({ config, scaffolder }) {
        scaffolder.addActions(createRenderSecureFastapiAction(config));
      },
    });
  },
});
