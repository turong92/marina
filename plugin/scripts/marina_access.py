"""Application-level project and resource ownership policy."""
from __future__ import annotations

from pathlib import Path
from typing import Callable

from marina_auth import AuthStore, SessionPrincipal
from marina_registry import project_for


def canonical_root(root: str | Path) -> str:
    return str(Path(root).expanduser().resolve())


def canonical_agent(source: str, sid: str) -> str:
    return f"{str(source).strip().lower()}:{str(sid).strip()}"


class AccessPolicy:
    def __init__(
        self,
        store: AuthStore,
        project_resolver: Callable[[Path], dict | None] = project_for,
    ):
        self.store = store
        self.project_resolver = project_resolver

    @staticmethod
    def is_admin(principal: SessionPrincipal | None) -> bool:
        return principal is not None and principal.user.role == "admin"

    def can_project(self, principal: SessionPrincipal | None, project_id: str) -> bool:
        if principal is None or self.is_admin(principal):
            return True
        return str(project_id) in self.store.project_access_for(principal.user.id)

    def can_resource(
        self, principal: SessionPrincipal | None, resource_type: str, resource_key: str
    ) -> bool:
        if principal is None or self.is_admin(principal):
            return True
        return self.store.resource_owner(resource_type, resource_key) == principal.user.id

    def can_root(self, principal: SessionPrincipal | None, root: str | Path) -> bool:
        if principal is None or self.is_admin(principal):
            return True
        project = self.project_resolver(Path(root))
        return bool(
            project and self.can_project(principal, str(project.get("id") or ""))
            and self.can_resource(principal, "worktree", canonical_root(root))
        )

    def assign(
        self,
        principal: SessionPrincipal | None,
        resource_type: str,
        resource_key: str,
        parent_root: str | Path | None = None,
    ) -> None:
        if principal is not None and self.store.resource_owner(resource_type, resource_key) is None:
            parent_key = canonical_root(parent_root) if parent_root is not None else None
            self.store.assign_resource_owner(
                resource_type, resource_key, principal.user.id, actor_user_id=principal.user.id,
                parent_type="worktree" if parent_key else None, parent_key=parent_key,
            )

    def inherit_from_root(self, resource_type: str, resource_key: str, root: str | Path) -> int | None:
        parent_key = canonical_root(root)
        owner = self.store.resource_owner("worktree", parent_key)
        resource_owner = self.store.resource_owner(resource_type, resource_key)
        if owner is not None and resource_owner is None:
            self.store.assign_resource_owner(
                resource_type, resource_key, owner,
                parent_type="worktree", parent_key=parent_key,
            )
            resource_owner = owner
        elif resource_owner is not None and self.store.resource_parent(
            resource_type, resource_key
        ) != ("worktree", parent_key):
            self.store.assign_resource_owner(
                resource_type, resource_key, resource_owner,
                parent_type="worktree", parent_key=parent_key,
            )
        return resource_owner
