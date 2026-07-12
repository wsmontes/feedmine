from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol, runtime_checkable

if TYPE_CHECKING:
    import aiohttp
    from scripts.feed_discovery.models import Candidate
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig


@dataclass
class ProbeResult:
    """Resultado de um probe de fonte para um pais."""
    source_name: str
    success: bool
    result_count: int
    latency_ms: float
    error: str = ""


@runtime_checkable
class SourceProtocol(Protocol):
    """Interface que toda fonte de descoberta deve implementar.

    Para adicionar uma nova fonte, crie um arquivo em sources/
    com uma classe que implementa esta interface. O sistema
    descobre fontes automaticamente via name.
    """
    name: str

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Busca feeds/podcasts/canais para uma query.

        Args:
            query: Termo de busca (ex: "Lagos Nigeria news").
            profile: Perfil do pais alvo.
            config: Configuracao desta fonte para este pais.
            session: Sessao aiohttp compartilhada.

        Returns:
            Lista de Candidate (url, title, category, genre, national).
        """
        ...

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Testa se a fonte funciona para este pais.

        Deve usar uma query generica (ex: nome do pais no idioma local)
        e retornar metricas. Nao deve fazer mais de 3 chamadas de rede.

        Args:
            profile: Perfil do pais a testar.
            config: Configuracao desta fonte.
            session: Sessao aiohttp compartilhada.

        Returns:
            ProbeResult com success, result_count, latency_ms.
        """
        ...
