# What does not work

This page records current limitations and alternatives.
It does not describe proposed features as available behavior.

| Limitation | Available alternative |
| --- | --- |
| No built-in Jira, Azure DevOps, or ServiceNow connector. | Write a handler that maps events to the public job API. |
| The GitHub example does not post its terminal result back to the issue. | Implement `on_terminal` with your integration credentials. |
| No public webhook-configuration endpoint. | Configure the token through the server-side integration function. |
| No public archive-download endpoint for the `files` sink. | Retrieve the archive from manager storage through an operator-controlled channel. |
| No public client MCP endpoint. | Use the HTTP API or bundled Agent Skill. |
| Identity MCP configuration currently reaches OpenCode only. | Use an OpenCode preset for GitHub identity operations. |
| Identity broker tests use a simulated GitHub service. | Validate a real App with its actual permissions before production use. |
| Kata smoke evidence covers runtime selection and exec only. | Check the actual workload's mounts, network, credentials, and resource behavior. |
| A job cannot select a specific worker or request GPU placement. | Configure the available fleet and its local capacity. |
| OAuth refresh does not update the original host credential file. | Renew authentication on the execution machine when the source expires. |
| The browser exposes Home and configuration, without dedicated job pages. | Use the public API for job details, cancellation, retry, and events. |

See [validation results](internal/validation-results.md) for current evidence limits.
