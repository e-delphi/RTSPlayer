# vendor/onnx-pascal

Cópia literal de units do projeto **onnx-pascal**
(`OneDrive\Documentos\git\onnx-pascal\delphi\src`), trazidas em 23/08/2026.

**Não edite nada aqui.** É código de terceiro copiado sem uma vírgula de
diferença, justamente para que comparar com o original continue sendo um `diff`
limpo e para que uma correção lá em cima chegue aqui com um `cp`. Toda a
adaptação ao VMS vive em `vms/src/Analytics`, do lado de cá da fronteira.

## O que veio, e por quê só isto

| unit | papel |
|---|---|
| `ONNX.CApi.pas` | ABI da C API do onnxruntime |
| `ONNX.Types.pas` | `IONNXRuntime`, `IONNXSession`, tensores |
| `ONNX.Runtime.pas` | carrega a DLL, cria env/allocator |
| `ONNX.Session.pas` | executa o grafo |
| `Vision.Types.pas` | caixa, detecção, resultado |
| `Vision.Image.pas` | buffer RGB + resample bilinear |
| `Vision.Preprocess.pas` | letterbox e normalização |
| `Vision.Nms.pas` | supressão não-máxima |
| `Vision.Model.pas` | metadados do modelo (inclusive os nomes das classes) |
| `Vision.Decoder.pas` | registro de decoders |
| `Vision.Decoder.Detect.pas` | a única cabeça que o VMS usa |
| `Vision.Predictor.pas` | orquestra sessão + preprocess + decoder |

Ficaram de fora as cabeças que o VMS não usa (classify, segment, pose, obb),
todo o pipeline facial (SCRFD, ArcFace, galeria), o renderizador, os relatórios
de console e o parser de linha de comando. Se um dia a detecção facial entrar,
o caminho é copiar as units que faltam e escrever outro `IObjectDetector` — não
mexer nas que estão aqui.

## O que precisa estar ao lado do vmsserver.exe

Já está tudo em `vms/bin` (pasta fora do git, ver `.gitignore`):

| arquivo | tamanho | de onde veio |
|---|---|---|
| `onnxruntime.dll` | 15 MB | `onnx-pascal\delphi\bin` |
| `yolo26x.onnx` | 223 MB | `onnx-pascal\delphi\bin\yolo` |
| `MSVCP140.dll`, `MSVCP140_1.dll` | 680 KB | `System32` |
| `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll` | 230 KB | `System32` |

As quatro do runtime da Microsoft acompanham porque o `onnxruntime.dll` as
importa diretamente. Nesta máquina elas já existem no sistema (o Delphi as
instala), mas numa máquina limpa sem o "VC++ 2015-2022 redistributable" a DLL do
ONNX não carrega — e a cópia ao lado do executável é a forma suportada de
resolver isso sem instalador. O resto do que ele importa (`api-ms-win-crt-*`) é
o Universal CRT, que faz parte do Windows 10 em diante.

Sem a DLL ou sem o modelo o servidor **sobe do mesmo jeito**: a detecção de
objetos fica desligada e a de movimento, que é pura aritmética, continua
gerando eventos. Ver `BuildAnalytics` em `Vms.Server.Composition`.
