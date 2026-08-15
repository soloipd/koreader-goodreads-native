import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.Reader;
import java.util.Map;

import org.codehaus.janino.SimpleCompiler;

/** Writes Janino's in-memory compiler output to ordinary .class files. */
public final class BuildWithJanino {
    private BuildWithJanino() {}

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: BuildWithJanino <output-dir> <source.java>...");
            System.exit(2);
        }

        File outputDirectory = new File(args[0]);
        if (!outputDirectory.isDirectory() && !outputDirectory.mkdirs()) {
            throw new IllegalStateException("cannot create " + outputDirectory);
        }

        for (int index = 1; index < args.length; index++) {
            String sourcePath = args[index];
            SimpleCompiler compiler = new SimpleCompiler();
            Reader source = new FileReader(sourcePath);
            try {
                compiler.cook(sourcePath, source);
            } finally {
                source.close();
            }

            for (Map.Entry<String, byte[]> entry : compiler.getBytecodes().entrySet()) {
                String className = (String) entry.getKey();
                File classFile = new File(
                    outputDirectory,
                    className.replace('.', File.separatorChar) + ".class"
                );
                File parent = classFile.getParentFile();
                if (!parent.isDirectory() && !parent.mkdirs()) {
                    throw new IllegalStateException("cannot create " + parent);
                }
                FileOutputStream output = new FileOutputStream(classFile);
                try {
                    output.write((byte[]) entry.getValue());
                } finally {
                    output.close();
                }
                System.out.println(classFile.getPath());
            }
        }
    }
}
