# Storage

- Page-based storage with 8 KB pages.
- io_uring-backed asynchronous non-blocking I/O.
- Slotted pages for variable-length tuples; packed 16-byte header.
- B+Tree indexes for primary and secondary keys.
- Durability via Write-Ahead Log (Aries).

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#2563eb', 'secondaryColor': '#64748b', 'borderRadius': '6px'}}}%%
graph TD
    subgraph Page Structure
        A[8 KB Page] --> B[16-byte Header]
        A --> C[Slotted Area<br/>Slot Array]
        A --> D[Tuple Payload<br/>Variable Length]
    end
    
    subgraph Header
        B --> B1[Page ID]
        B --> B2[LSN<br/>Log Sequence Number]
        B --> B3[Slot Count]
        B --> B4[Free Space Offset]
        B --> B5[Page Type]
        B --> B6[Checksum]
    end
    
    subgraph BTree Index
        E[B+Tree Root] --> F[Internal Nodes]
        E --> G[Leaf Nodes]
        F --> H[Keys + Pointers]
        G --> I[Keys + Records]
    end
    
    subgraph WAL
        J[Write-Ahead Log<br/>Aries Protocol] --> J1[Log Buffer]
        J --> J2[Commit Records]
        J --> J3[Abort Records]
        J --> J4[Checkpoint Records]
    end
    
    A --> E
    A --> J
```