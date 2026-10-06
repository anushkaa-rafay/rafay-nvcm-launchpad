// The one place the dashboard is pointed at a repository. No credentials belong here — ever: this file is
// published as-is to anyone who can open the page.
export const CONFIG = {
  owner: 'ramakrishna-rafay',
  repo: 'rafay_nvcm_launchpad',
  pageSize: 100,              // runs per API page (GitHub's maximum)
  maxPages: 30,               // ≤ 3,000 runs per load; date-filtered queries are capped at 1,000 by GitHub anyway
  autoRefreshMs: 5 * 60e3,    // auto-refresh interval while the tab is visible (toggle in the header)
  tableStep: 25,              // Recent Runs rows per "Show more"
};

export const repoUrl = `https://github.com/${CONFIG.owner}/${CONFIG.repo}`;
export const actionsUrl = `${repoUrl}/actions`;
